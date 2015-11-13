mtype = { NONE, GET, POST, DATA, GOAWAY }

#define STATE_IDLE                0
#define STATE_OPEN                1
#define STATE_READY               2
#define STATE_HALF_CLOSED_LOCAL   3
#define STATE_HALF_CLOSED_REMOTE  4
#define STATE_RESET_STREAM        5
#define STATE_CLOSED              6
#define STATE_ERROR               7

#define EVENT_NONE                0
#define EVENT_RESET_RECEIVED      1
#define EVENT_GOAWAY_RECEIVED     2
#define EVENT_RESET_RECEIVED      1

#define FIRST_STREAM_ID           1
#define MAX_CONCURRENT_STREAMS    5
#define MAX_DATA_FRAMES           5    /* must range from 1 to 15 */
#define MAX_ACTIVE_CONNECTIONS    1

#define LARGEST_CLIENT_STREAM_ID      15
#define LARGEST_SERVER_PUSH_STREAM_ID 100

typedef Stream {
    unsigned id: 10;
    unsigned client_state: 4;
    unsigned server_state: 4;
    unsigned final_frame: 4;
    unsigned last_sent_frame: 4;
    unsigned last_rcvd_frame: 4;
    mtype request;
};

Stream streams[MAX_CONCURRENT_STREAMS];

chan server  = [1] of {mtype, byte, int , byte, byte};

#define CLIENT_CHAN_CAP (MAX_CONCURRENT_STREAMS * MAX_DATA_FRAMES)
chan client  = [CLIENT_CHAN_CAP] of {mtype, byte, int , byte, byte};

chan client_tasks = [MAX_CONCURRENT_STREAMS] of { byte }
chan server_tasks = [MAX_CONCURRENT_STREAMS] of { byte }

unsigned active_streams: 16    = 0;
unsigned last_stream_id: 16    = 1;
unsigned goaway_stream_id: 16  = 0;
bit goaway_rcvd = 0;
bit goaway_sent = 0;

inline next_stream_id(index, stream)
{
    short new_stream_id = 0;
    byte dist = 1;
    byte free = 0;

    atomic {
        if
        :: (active_streams < MAX_CONCURRENT_STREAMS) ->
        {
            do
            :: (streams[free].id == 0) -> break;
            :: (streams[free].id > 0) -> free++;
            od
            new_stream_id = last_stream_id + 2;
            streams[free].id = new_stream_id;
            last_stream_id = new_stream_id;
            stream = new_stream_id;
            index = free;
            active_streams++;
        }
        :: else -> stream = 0;
        fi
    }
}

inline stream_initialize(i, sid, req)
{
  atomic {
    if
    :: (i >= 0 && i < MAX_CONCURRENT_STREAMS) -> {
        streams[i].id = sid;
        streams[i].client_state = STATE_IDLE;
        streams[i].server_state = STATE_IDLE;
        streams[i].final_frame = 0;
        streams[i].last_sent_frame = 0;
        streams[i].last_rcvd_frame = 0;
        streams[i].request = req;
    }
    :: else -> assert(0);
    fi
  }
}

inline server_stream_reset(i, sid)
{
    assert(i >= 0 && i < MAX_CONCURRENT_STREAMS)
    assert(streams[i].id == sid);
    atomic {
        streams[i].server_state = STATE_CLOSED;
        if
        :: (streams[i].client_state == STATE_CLOSED) -> {
            stream_initialize(i, 0, NONE)
            active_streams--;
        }
        :: else -> skip;
        fi
    }
}

inline client_stream_reset(i, sid)
{
    assert(streams[i].id == sid);
    atomic {
        streams[i].client_state = STATE_CLOSED;
        if
        :: (streams[i].server_state == STATE_CLOSED) -> {
            stream_initialize(i, 0, NONE)
            active_streams--;
        }
        :: else -> skip;
        fi
    }
}

inline nondet_obtain(n)
{
/*
    if
    :: n = 1;
    :: n = 2;
    :: n = 3;
    :: n = 5;
    :: n = 7;
    :: n = 11;
    :: n = 13;
    fi

    n = n % (MAX_DATA_FRAMES + 1);
*/
    n = MAX_DATA_FRAMES;
}

proctype Client()
{
    unsigned sid: 16;
    byte indx;
    byte frame, data_frames;

end:
progress:
    do
    :: server?GOAWAY(0, sid, 0, 0) -> {
        assert(sid > 0 && sid <= last_stream_id);
        
        goaway_rcvd = true;
        goaway_stream_id = sid;
    }

    :: server?DATA(indx, sid, frame, data_frames) -> {
        assert(sid > 0);
        assert(!goaway_rcvd || sid <= goaway_stream_id);
        assert(indx >= 0 && indx < MAX_CONCURRENT_STREAMS);
        assert(frame > 0 && frame <= data_frames)
        assert(streams[indx].id == sid);
        assert(streams[indx].last_rcvd_frame + 1 == frame);
        assert(streams[indx].client_state == STATE_OPEN || 
               streams[indx].client_state == STATE_HALF_CLOSED_LOCAL ||
               streams[indx].client_state == STATE_HALF_CLOSED_REMOTE);

        streams[indx].last_rcvd_frame = frame;
        if 
        :: (frame == data_frames) -> {
            client_stream_reset(indx, sid)
        }
        :: else -> skip;
        fi
    }

    :: (!goaway_rcvd && active_streams < MAX_CONCURRENT_STREAMS) -> 
    {
        next_stream_id(indx, sid)
        if
        :: (sid > 0) -> {
            stream_initialize(indx, sid, GET);
            streams[indx].client_state = STATE_HALF_CLOSED_LOCAL;
            client!GET(indx, sid, 0, 0);
        }

        :: (sid > 0) -> {
            stream_initialize(indx, sid, POST);
            nondet_obtain(data_frames);
            assert(data_frames > 0);
            atomic {
              streams[indx].final_frame = data_frames
              streams[indx].client_state = STATE_OPEN;
              client!POST(indx, sid, 0, data_frames);
            }
            client_tasks!indx;
        }
        
        :: else -> assert(0);
        fi
    }

    :: client_tasks?indx -> {
        assert(streams[indx].request == POST);
        assert(streams[indx].client_state == STATE_OPEN)
        frame = streams[indx].last_sent_frame + 1
        data_frames = streams[indx].final_frame
        assert(frame <= data_frames)
        sid = streams[indx].id
        if
        :: (goaway_rcvd && sid > goaway_stream_id) -> {
            streams[indx].client_state = STATE_CLOSED;
            client_stream_reset(indx, streams[indx].id);
        }
        :: (frame <= data_frames) -> {
            streams[indx].last_sent_frame = frame
            client!DATA(indx, sid, frame, data_frames);
            if
            :: (frame < data_frames) -> {
                client_tasks!indx;
            }
            :: else -> {
                streams[indx].client_state = STATE_CLOSED;
                client_stream_reset(indx, streams[indx].id);
            }
            fi
        }
        fi
    }

    :: timeout -> {
        byte i = 0;
        do
        :: (goaway_rcvd && active_streams > 0) -> {
            if
            :: (i < MAX_CONCURRENT_STREAMS && streams[i].id > goaway_stream_id) -> {
                client_stream_reset(i, streams[i].id)
                active_streams--;
            }
            :: (i >= MAX_CONCURRENT_STREAMS) -> break;
            :: else -> i++;
            fi
        }
        :: else -> break;
        od

        if
        :: (active_streams == 0) -> {
            client!GOAWAY(0, 0, 0, 0)
            break;
        }
        :: else -> skip;
        fi
    }
    od

    printf("goaway stream id: %d\n", goaway_stream_id);
    printf("last stream id: %d\n", last_stream_id);
}

inline notify_goaway()
{
    if
    :: !goaway_sent -> {
        server!GOAWAY(0, LARGEST_CLIENT_STREAM_ID, 0, 0);
        goaway_sent = true;
    }
    :: else -> skip;
    fi
}

proctype Server()
{
    unsigned sid: 16;
    byte indx;
    byte frame, data_frames;

end:
progress:
    do
    :: client?GOAWAY(0, 0, 0, 0) -> break;

    :: client?GET(indx, sid, 0, 0) -> {
        if
        :: (sid > LARGEST_CLIENT_STREAM_ID) -> {
            notify_goaway()
        }
        :: else -> {
            nondet_obtain(data_frames)
            assert(data_frames > 0)
            assert(streams[indx].server_state == STATE_IDLE);
            streams[indx].last_sent_frame = 0
            streams[indx].final_frame = data_frames
            streams[indx].server_state = STATE_HALF_CLOSED_REMOTE
            server_tasks!indx
        }
        fi
    }

    :: client?POST(indx, sid, frame, data_frames) -> {
        if
        :: (sid > LARGEST_CLIENT_STREAM_ID) -> {
            notify_goaway()
        }
        :: else -> {
            assert(frame == 0 && data_frames > 0)
            assert(indx >= 0 && indx < MAX_CONCURRENT_STREAMS && sid > 0)
            assert(streams[indx].server_state == STATE_IDLE);
            streams[indx].last_rcvd_frame = 0
            streams[indx].final_frame = data_frames
            streams[indx].server_state = STATE_OPEN
        }
        fi
    }
    
    :: client?DATA(indx, sid, frame, data_frames) -> {
        assert(sid > 0);
        assert(indx >= 0 && indx < MAX_CONCURRENT_STREAMS);
        assert(frame > 0 && frame <= data_frames)
        assert(streams[indx].id == sid);
        assert(streams[indx].last_rcvd_frame + 1 == frame);
        assert(streams[indx].server_state == STATE_OPEN || 
               streams[indx].server_state == STATE_HALF_CLOSED_REMOTE ||
               (goaway_sent && streams[indx].server_state == STATE_IDLE))

        streams[indx].last_rcvd_frame = frame;
        if
        :: (frame == data_frames) -> {
            server_stream_reset(indx, sid)
        }
        :: else -> skip;
        fi
    }

    :: server_tasks?indx -> {
        assert(streams[indx].request == GET);
        assert(streams[indx].server_state == STATE_HALF_CLOSED_REMOTE);
        frame = streams[indx].last_sent_frame + 1
        sid = streams[indx].id
        data_frames = streams[indx].final_frame
        streams[indx].last_sent_frame = frame
        server!DATA(indx, sid, frame, data_frames);
        if
        :: (frame < data_frames) -> {
            server_tasks!indx
        }
        :: else -> {
            streams[indx].server_state = STATE_HALF_CLOSED_LOCAL;
            server_stream_reset(indx, sid)
        }
        fi
    }

    od
}

active proctype main()
{
    run Client();
    run Server();
}
