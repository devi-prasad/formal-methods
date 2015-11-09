mtype = { NONE, GET, POST, DATA, RST, GOAWAY }

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

#define FIRST_STREAM_ID        3
#define MAX_ACTIVE_STREAMS     3
#define MAX_DATA_FRAMES        3
#define MAX_ACTIVE_CONNECTIONS 1

#define LARGEST_CLIENT_STREAM_ID      251
#define LARGEST_SERVER_PUSH_STREAM_ID 100

typedef Stream {
    unsigned id: 8;
    unsigned client_state: 3;
    unsigned server_state: 3;
    unsigned final_frame: 3;
    unsigned last_sent_frame: 3;
    unsigned last_rcvd_frame: 3;
    mtype request;
    mtype verb;
};

Stream streams[MAX_ACTIVE_STREAMS];

chan server  = [1] of {mtype, byte, int , byte, byte};

#define CLIENT_CHAN_CAP (MAX_ACTIVE_STREAMS * MAX_DATA_FRAMES) + \
                        (MAX_ACTIVE_STREAMS * 2)
chan client  = [CLIENT_CHAN_CAP] of {mtype, byte, int , byte, byte};

/* indices of streams. ongoing transactions on the client */
chan client_tasks = [MAX_ACTIVE_STREAMS] of { byte }
/* indices of streams. ongoing transactions on the server */
chan server_tasks = [MAX_ACTIVE_STREAMS] of { byte }

byte streams_in_use      = 0;
byte last_stream_index   = 0;
byte last_stream_id      = 3;

inline next_stream_id(index, stream)
{
    byte new_stream_id = 0;
    byte dist = 1;
    byte free = 0;

    atomic {
        if
        :: (streams_in_use < MAX_ACTIVE_STREAMS) ->
        {
            do
            :: (streams[free].id == 0) -> break;
            :: (streams[free].id > 0) -> free++;
            od
            if
            :: (last_stream_index < free) -> dist = (free - last_stream_index);
            :: (last_stream_index == free) -> dist = 2;
            :: else -> dist = ((MAX_ACTIVE_STREAMS - last_stream_index) + (free + 1)); 
            fi
            new_stream_id = last_stream_id + (2 * dist);
            streams[free].id = new_stream_id;
            last_stream_index = free;
            last_stream_id = new_stream_id;
            stream = new_stream_id;
            index = free;
            streams_in_use++;
        }
        :: else -> stream = 0;
        fi
    }
}

inline stream_initialize(i, sid, req_verb)
{
  atomic {
    if
    :: (i >= 0 && i < MAX_ACTIVE_STREAMS) -> {
        streams[i].id = sid;
        streams[i].client_state = STATE_IDLE;
        streams[i].server_state = STATE_IDLE;
        streams[i].final_frame = 0;
        streams[i].last_sent_frame = 0;
        streams[i].last_rcvd_frame = 0;
        streams[i].request = req_verb;
        streams[i].verb = req_verb;
    }
    :: else -> assert(0);
    fi
  }
}

inline server_stream_reset(i, sid)
{
    assert(i >= 0 && i < MAX_ACTIVE_STREAMS)
    assert(streams[i].id == sid);
    atomic {
        streams[i].server_state = STATE_CLOSED;
        if
        :: (streams[i].client_state == STATE_CLOSED) -> {
            stream_initialize(i, 0, NONE)
            streams_in_use--;
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
            streams_in_use--;
        }
        :: else -> skip;
        fi
    }
}

inline nondet_obtain(n)
{
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
}

proctype Client()
{
    byte sid;
    byte indx;
    byte frame, data_frames;

end:
progress:
    do
    :: server?RST(indx, sid, 0, 0) -> {
        printf("client: RESET received: %d, %d\n", indx, sid);
        assert(sid > 0 && sid <= last_stream_id);
        assert(indx >= 0 && indx < MAX_ACTIVE_STREAMS);
        assert(streams[indx].id == sid);
        assert(streams[indx].client_state != STATE_IDLE);
      atomic {
        streams[indx].client_state = STATE_CLOSED;
        client_stream_reset(indx, sid);
      }
    }

    :: server?GOAWAY(0, 0, 0, 0) -> {
        printf("client: GOAWAY received\n");
    }

    :: server?DATA(indx, sid, frame, data_frames) -> {
        printf("client: DATA received - %d/%d\n", frame, data_frames);
        assert(sid > 0);
        assert(indx >= 0 && indx < MAX_ACTIVE_STREAMS);
        assert(frame > 0 && frame <= data_frames)
        assert(streams[indx].id == sid);
        assert(streams[indx].last_rcvd_frame + 1 == frame);
        assert(streams[indx].client_state == STATE_OPEN || 
               streams[indx].client_state == STATE_HALF_CLOSED_LOCAL ||
               streams[indx].client_state == STATE_HALF_CLOSED_REMOTE);

        if 
        :: (frame == data_frames) -> {
            printf("client:           last frame\ns")
        }
        :: else -> skip;
        fi
        streams[indx].last_rcvd_frame = frame;
    }

    :: (last_stream_id < LARGEST_CLIENT_STREAM_ID
            && streams_in_use < MAX_ACTIVE_STREAMS) -> {
        next_stream_id(indx, sid)
        if
        :: (sid > 0) -> {
            stream_initialize(indx, sid, GET);
            streams[indx].client_state = STATE_HALF_CLOSED_LOCAL;
            client!GET(indx, sid, 0, 0);
            printf("client: GET request sent\n")
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
            printf("Client: POST request sent on stream %d\n", sid)
            client_tasks!indx;
        }
        
        :: else -> assert(0);
        fi
    }

    :: client_tasks?indx -> {
        if        
        :: (streams[indx].verb == POST) -> {
            assert(streams[indx].client_state == STATE_OPEN)
            frame = streams[indx].last_sent_frame + 1
            data_frames = streams[indx].final_frame
            assert(frame <= data_frames)
            sid = streams[indx].id
            printf("Client: POST DATA - %d/%d\n", frame, data_frames)
            streams[indx].last_sent_frame = frame
            if
            :: (frame == data_frames) -> {
               streams[indx].client_state = STATE_HALF_CLOSED_LOCAL;
               streams[indx].verb = RST;
            }
            :: else -> skip;
            fi
            client!DATA(indx, sid, frame, data_frames);
            client_tasks!indx;
        }

        :: (streams[indx].verb == RST) -> {
            assert(streams[indx].client_state == STATE_HALF_CLOSED_LOCAL)
            client!RST(indx, streams[indx].id, 0, 0)
            atomic {
              streams[indx].client_state = STATE_CLOSED;
              client_stream_reset(indx, streams[indx].id);
            }
        }
        fi
    }

    :: (last_stream_id >= LARGEST_CLIENT_STREAM_ID && streams_in_use == 0) -> {
        client!GOAWAY(0, 0, 0, 0);
        printf("Client sent GOAWAY!!\n")
        break;
    }

    od
}

proctype Server()
{
    byte indx;
    byte sid;
    byte frame, data_frames;

end:
progress:
    do
    :: client?RST(indx, sid, 0, 0) -> {
        printf("Server: RESET received: %d, %d\n", indx, sid);
        assert(sid > 0);
        assert(indx >= 0 && indx < MAX_ACTIVE_STREAMS);
        assert(streams[indx].server_state != STATE_IDLE);
        server_stream_reset(indx, sid)
    }

    :: client?GET(indx, sid, 0, 0) -> {
        nondet_obtain(data_frames)
        assert(data_frames > 0)
        assert(streams[indx].server_state == STATE_IDLE);
        streams[indx].last_sent_frame = 0
        streams[indx].final_frame = data_frames
        streams[indx].server_state = STATE_HALF_CLOSED_REMOTE
        assert(streams[indx].request == GET);
        server_tasks!indx
    }

    :: client?POST(indx, sid, frame, data_frames) -> {
        assert(frame == 0 && data_frames > 0)
        assert(indx >= 0 && indx < MAX_ACTIVE_STREAMS && sid > 0)
        assert(streams[indx].server_state == STATE_IDLE);
        assert(streams[indx].request == POST)
        printf("Server - POST request received\n")
        streams[indx].last_rcvd_frame = 0
        streams[indx].final_frame = data_frames
        streams[indx].server_state = STATE_OPEN
    }
    
    :: client?DATA(indx, sid, frame, data_frames) -> {
        printf("Server: DATA received - %d/%d\n", frame, data_frames);
        assert(sid > 0);
        assert(indx >= 0 && indx < MAX_ACTIVE_STREAMS);
        assert(frame > 0 && frame <= data_frames)
        assert(streams[indx].id == sid);
        assert(streams[indx].client_state == STATE_CLOSED || 
               streams[indx].last_rcvd_frame + 1 == frame);
        assert(streams[indx].server_state == STATE_OPEN || 
               streams[indx].server_state == STATE_HALF_CLOSED_REMOTE ||
               streams[indx].client_state == STATE_HALF_CLOSED_LOCAL ||
               streams[indx].client_state == STATE_CLOSED);

        if 
        :: (frame == data_frames) -> {
            printf("server:           last frame\ns")
            assert(streams[indx].client_state == STATE_HALF_CLOSED_LOCAL ||
                   streams[indx].client_state == STATE_CLOSED);
            streams[indx].server_state = STATE_HALF_CLOSED_REMOTE
        }
        :: else -> skip;
        fi
        streams[indx].last_rcvd_frame = frame;
    }

    :: server_tasks?indx -> {
        if
        :: (streams[indx].verb == GET) -> {
            assert(streams[indx].server_state == STATE_HALF_CLOSED_REMOTE);
            //assert(streams[indx].client_state == STATE_HALF_CLOSED_LOCAL);
            frame = streams[indx].last_sent_frame + 1
            sid = streams[indx].id
            data_frames = streams[indx].final_frame
            server!DATA(indx, sid, frame, data_frames);
            streams[indx].last_sent_frame = frame
            printf("SERVER: sent GET DATA - %d/%d\n", frame, data_frames)
            if
            :: (frame == data_frames) -> {
                streams[indx].server_state = STATE_HALF_CLOSED_LOCAL;
                streams[indx].verb = RST
            }
            :: else -> skip;
            fi
            server_tasks!indx
        }
        :: (streams[indx].verb == RST) -> {
            assert(streams[indx].server_state == STATE_HALF_CLOSED_LOCAL);
            assert(streams[indx].last_sent_frame == streams[indx].final_frame)
            assert(streams[indx].id > 0)
            server!RST(indx, streams[indx].id, 0, 0);
            server_stream_reset(indx, streams[indx].id)
            printf("SERVER: sent GET RST sent\n")
        }
        fi
    }

    :: client?GOAWAY(0, 0, 0, 0) -> break;
    od
}

active proctype main()
{
    run Client();
    run Server();
}
