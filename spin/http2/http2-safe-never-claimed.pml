mtype = { NONE, GET, POST, DATA, GOAWAY, RST }

#define STATE_IDLE                0
#define STATE_OPEN                1
#define STATE_READY               2
#define STATE_HALF_CLOSED_LOCAL   3
#define STATE_HALF_CLOSED_REMOTE  4
#define STATE_RESET_STREAM        5
#define STATE_CLOSED              6
#define STATE_ERROR               7

#define CLIENT_FIRST_STREAM_ID    1
#define MAX_CSTREAMS              5
#define MAX_DATA_FRAMES           7

#define CLIENT_GOAWAY_STREAM_ID   51
#define CLIENT_LARGEST_STREAM_ID  61
#define SERVER_MAX_PUSH_STREAM_ID 100

#define STREAM_ID_BITS   6
#define STATE_BITS       4
#define DATA_FRAME_BITS  6

typedef Stream {
    unsigned id: STREAM_ID_BITS;
    unsigned state: STATE_BITS;
    unsigned final_frame: DATA_FRAME_BITS;
    unsigned prev_frame: DATA_FRAME_BITS;
    mtype request;
};

Stream cstreams[MAX_CSTREAMS];
Stream sstreams[MAX_CSTREAMS];

chan server  = [1] of {mtype, byte, int , byte, byte};

#define CLIENT_CHAN_CAP ((MAX_CSTREAMS * MAX_DATA_FRAMES) + MAX_CSTREAMS)
chan client  = [CLIENT_CHAN_CAP] of {mtype, byte, int , byte, byte};

local unsigned active_streams: STREAM_ID_BITS;
local unsigned last_sid: STREAM_ID_BITS;
local unsigned goaway_sid: STREAM_ID_BITS;
local bit goaway_rcvd;
local bit goaway_sent;
local bit bask;

inline system_state_reset()
{
  atomic {
    active_streams = 0;
    last_sid = CLIENT_FIRST_STREAM_ID;
    goaway_sid = 0;
    goaway_rcvd = 0;
    goaway_sent = 0;
    bask = 0;
    // TODO - flush all active channels
  }
}

inline client_stream_new(index, stream)
{
    unsigned new_sid: STREAM_ID_BITS = 0;
    byte free = 0;

    if :: (!goaway_rcvd && active_streams < MAX_CSTREAMS && 
           last_sid < CLIENT_LARGEST_STREAM_ID) -> {
        do
        :: (free < MAX_CSTREAMS && cstreams[free].id == 0) -> break;
        :: (free < MAX_CSTREAMS && cstreams[free].id > 0) -> free++;
        :: (free >= MAX_CSTREAMS) -> assert(false);
        od
        new_sid = last_sid + 2;
        cstreams[free].id = new_sid;
        last_sid = new_sid;
        stream = new_sid;
        index = free;
        active_streams++;
    }
    :: else -> stream = 0;
    fi
}

inline client_stream_init(i, sid, req)
{
    assert(i >= 0 && i < MAX_CSTREAMS);

    cstreams[i].id = sid;
    cstreams[i].state = STATE_IDLE;
    cstreams[i].final_frame = 0;
    cstreams[i].prev_frame = 0;
    cstreams[i].request = req;
}

inline client_stream_reset(i)
{
    assert(i >= 0 && i < MAX_CSTREAMS);
    client_stream_init(i, 0, NONE)
    active_streams--;
}

inline generate_data_frames(n)
{
    if :: n = MAX_DATA_FRAMES;   :: n = MAX_DATA_FRAMES + 1;
    :: n = MAX_DATA_FRAMES + 2;  :: n = MAX_DATA_FRAMES + 3;
    :: n = MAX_DATA_FRAMES + 4;  :: n = MAX_DATA_FRAMES + 5;
    :: n = MAX_DATA_FRAMES + 6;  :: n = MAX_DATA_FRAMES - 1;
    fi

    n = (n % MAX_DATA_FRAMES) + 1;
    assert(n > 0 && n <= MAX_DATA_FRAMES);
}

inline client_drop_get_requests()
{
    i = 0;
    do
    :: (goaway_rcvd && i < MAX_CSTREAMS) -> {
        if :: (cstreams[i].id > goaway_sid && cstreams[i].request == GET) -> {
            client_stream_reset(i)
        }
        :: else -> skip;
        fi
        i++;
    }
    :: else -> break;
    od
}

inline client_http_get(i, sid)
{
    i = 0; sid = 0;
    client_stream_new(i, sid)
    if :: (sid > 0) -> {
        client_stream_init(i, sid, GET)
        cstreams[i].state = STATE_HALF_CLOSED_LOCAL;
        client!GET(i, sid, 0, 0);
    }
    :: else -> skip;
    fi
}

inline client_http_post(i, sid, n)
{
    i = 0; sid = 0; n = 0;
    client_stream_new(i, sid)
    if :: (sid > 0) -> {
        client_stream_init(i, sid, POST)
        generate_data_frames(n)
        cstreams[i].final_frame = n
        cstreams[i].state = STATE_OPEN;
        client!POST(i, sid, 0, n);
        client_tasks!i;
    }
    :: else -> skip;
    fi
}

inline client_receive_data(i, sid, cur, final)
{
    assert(sid > 0 && i >= 0 && i < MAX_CSTREAMS);
    assert(cur > 0 && cur <= final);
    assert(cur == 1 || final >= cstreams[i].final_frame)
    assert(cstreams[i].request == GET);
    assert(cstreams[i].state == STATE_HALF_CLOSED_LOCAL);
    assert(cstreams[i].id == sid);
    assert(cstreams[i].prev_frame + 1 == cur);
    
    cstreams[i].prev_frame = cur;
    cstreams[i].final_frame = final;
    if :: (cur == final) -> {
        client_stream_reset(i)
    }
    :: else -> skip;
    fi
}

inline client_react_to_goaway(sid)
{
    if :: (sid > 0) -> {
        goaway_rcvd = true;
        goaway_sid = sid;
        client_drop_get_requests(); // POST requests can't be purged now.
    }
    :: else -> skip; // TODO - graceful shutdown sequence per HTTP/2 spec.
    fi
}

inline client_perform_next_task(i)
{
    assert(cstreams[i].request == POST)
    assert(cstreams[i].state == STATE_OPEN)
    cur = cstreams[i].prev_frame + 1
    final = cstreams[i].final_frame
    assert(cur <= final)
    sid = cstreams[i].id

    if :: (goaway_rcvd && sid > goaway_sid) -> {
        client_stream_reset(i);
    }
    :: (cur <= final) -> {
        cstreams[i].prev_frame = cur
        client!DATA(i, sid, cur, final);
        if
        :: (cur < final) -> client_tasks!i;
        :: else -> client_stream_reset(i);
        fi
    }
    :: else -> assert(false);
    fi
}

proctype Client()
{
    byte i, n;
    unsigned sid: STREAM_ID_BITS;
    unsigned cur: DATA_FRAME_BITS;
    unsigned final: DATA_FRAME_BITS;
    chan client_tasks = [MAX_CSTREAMS] of { byte }

    xr server;
    xs client;

    bask = false;

progress_client:
end_client:
    do
    :: (goaway_rcvd && bask) -> end_client_bask: skip;
    :: server?GOAWAY(0, sid, 0, 0) -> progress_goaway: client_react_to_goaway(sid);
    :: (goaway_rcvd && !active_streams && !bask) -> accept_bask: bask = true;
    :: !goaway_rcvd && active_streams < MAX_CSTREAMS &&
           last_sid < CLIENT_LARGEST_STREAM_ID -> client_http_get(i, sid);
    :: !goaway_rcvd && active_streams < MAX_CSTREAMS &&
           last_sid < CLIENT_LARGEST_STREAM_ID -> client_http_post(i, sid, n);
    :: server?DATA(i, sid, cur, final) -> client_receive_data(i, sid, cur, final);
    :: client_tasks?i -> client_perform_next_task(i);
    :: timeout -> assert(false);
    od
}

inline notify_goaway()
{
    if :: !goaway_sent -> {
        goaway_sent = true;
        server!GOAWAY(0, CLIENT_GOAWAY_STREAM_ID, 0, 0);
    }
    :: goaway_sent -> skip;
    fi
}

inline server_stream_init(i, sid, req)
{
    assert(i >= 0 && i < MAX_CSTREAMS);

    sstreams[i].id = sid;
    sstreams[i].state = STATE_IDLE;
    sstreams[i].final_frame = 0;
    sstreams[i].prev_frame = 0;
    sstreams[i].request = req;
}

inline server_stream_reset(i)
{
    assert(i >= 0 && i < MAX_CSTREAMS && sstreams[i].id > 0);
    server_stream_init(i, 0, NONE)
}

inline serve_http_get(i, sid, n)
{
    assert(cstreams[i].state == STATE_HALF_CLOSED_LOCAL);
    assert(!goaway_sent || sid <= CLIENT_GOAWAY_STREAM_ID)
    generate_data_frames(n)
    server_stream_init(i, sid, GET)
    sstreams[i].final_frame = n
    sstreams[i].state = STATE_HALF_CLOSED_REMOTE
    server_tasks!i
}

inline serve_http_post(i, sid, n)
{
    assert(i >= 0 && i < MAX_CSTREAMS && sid > 0 && n > 0)
    server_stream_init(i, sid, POST)
    sstreams[i].final_frame = n
    sstreams[i].state = STATE_OPEN
}

inline server_receive_data(i, sid, cur, final)
{
    if :: (!goaway_sent || goaway_sid >= sid) -> {
        assert(i >= 0 && i < MAX_CSTREAMS && sid > 0);
        assert(cur > 0 && final >= cur);
        assert(sstreams[i].id == sid);
        assert(sstreams[i].state == STATE_OPEN);
//        assert((sstreams[i].prev_frame + 1) == cur);

        sstreams[i].prev_frame = cur;
        if :: (cur == final) -> server_stream_reset(i)
        :: else -> skip;
        fi
    }
    :: else -> skip;
    fi
}

inline server_task_next(i)
{
    assert(sstreams[i].request == GET);
    assert(sstreams[i].state == STATE_HALF_CLOSED_REMOTE);
    cur = sstreams[i].prev_frame + 1
    sid = sstreams[i].id
    final = sstreams[i].final_frame

    sstreams[i].prev_frame = cur
    server!DATA(i, sid, cur, final);
    if :: (cur < final) -> server_tasks!i
    :: else -> server_stream_reset(i)
    fi
}

proctype Server()
{
    byte i, n;
    unsigned sid: STREAM_ID_BITS;
    unsigned cur: DATA_FRAME_BITS;
    unsigned final: DATA_FRAME_BITS;
    chan server_tasks = [MAX_CSTREAMS] of { byte }

    xs server;
    xr client;

end_server:
progress_server:
    do
    :: client?GOAWAY(0, 0, 0, 0) -> break;
    :: client?GET(i, sid, 0, 0) -> {
        if :: (sid <= CLIENT_GOAWAY_STREAM_ID) -> serve_http_get(i, sid, n)
        :: else -> notify_goaway()
        fi
    }
    :: client?POST(i, sid, 0, final) -> {
        if :: (sid <= CLIENT_GOAWAY_STREAM_ID) -> serve_http_post(i, sid, final);
        :: else -> notify_goaway()
        fi
    }
    :: client?DATA(i, sid, cur, final) -> server_receive_data(i, sid, cur, final)
    :: server_tasks?i -> server_task_next(i)
    :: timeout -> assert(false);
    od
}

active proctype main()
{
    byte indx;
    byte stream;

    system_state_reset()

    run Client();
    run Server();
}

never {
init_S0:
progress_S0:
    if
    :: !goaway_sent && !goaway_rcvd -> goto init_S0;
    :: goaway_sent -> goto S1;
    :: goaway_rcvd -> assert(false);
    fi

accept_no_goaway_rcvd:
progress_S1:
S1:
    if
    :: goaway_sent && !goaway_rcvd -> goto S1;
    :: goaway_rcvd -> goto S2;
    :: else -> goto S1;
    fi

accept_no_bask:
progress_S2:
S2:
    if
    :: goaway_sent && goaway_rcvd && !bask -> goto S2;
    :: goaway_sent && goaway_rcvd && bask -> goto joy_forever;
    fi

joy_forever:
progerss_joy_forever:
    do
    :: goaway_sent && goaway_rcvd && bask -> assert(active_streams == 0);
    od
}
