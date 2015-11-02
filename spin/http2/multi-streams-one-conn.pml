mtype = { GET, POST, DATA, RST, GOAWAY, STATUS }

#define STATE_IDLE                0
#define STATE_OPEN                1
#define STATE_READY               2
#define STATE_HALF_CLOSED_LOCAL   4
#define STATE_HALF_CLOSED_REMOTE  8
#define STATE_RESET_STREAM        16
#define STATE_CLOSED              32
#define STATE_ERROR               64

#define EVENT_NONE                0
#define EVENT_RESET_RECEIVED      1
#define EVENT_GOAWAY_RECEIVED     2
#define EVENT_RESET_RECEIVED      1

#define FIRST_STREAM_ID    3
#define MAX_STREAMS        4
#define MAX_CONNECTIONS    1

typedef Stream {
    unsigned id: 31;
    unsigned state: 6;
    unsigned final_frame: 3;
    unsigned prev_frame: 3;
    mtype event;
};
Stream streams[MAX_STREAMS];

chan server = [1] of {mtype, byte, int , byte, byte};
chan client = [MAX_STREAMS] of {mtype, byte, int , byte, byte};

byte streams_in_use      = 0;
byte last_stream_index   = 0;
int  last_stream_id      = 3;

inline next_stream_id(index, stream)
{
    int new_stream_id = 0;
    byte dist = 1;
    byte free = 0;

    atomic {
        if
        :: (streams_in_use < MAX_STREAMS) ->
        {
            do
            :: (streams[free].id == 0) -> break;
            :: (streams[free].id > 0) -> free++;
            od
            if
            :: (last_stream_index < free) -> dist = (free - last_stream_index);
            :: (last_stream_index == free) -> dist = 2;
            :: else -> dist = ((MAX_STREAMS - last_stream_index) + (free + 1)); 
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

inline stream_initialize(i, sid)
{
  atomic {
    if
    :: (i >= 0 && i < MAX_STREAMS) -> {
        streams[i].id = sid;
        streams[i].state = STATE_IDLE;
        streams[i].final_frame = 0;
        streams[i].prev_frame = 0;
        streams[i].event = EVENT_NONE;
    }
    :: (i < 0 || i > MAX_STREAMS) -> assert(0);
    fi
  }
}

inline stream_reset(i, sid)
{
    assert(streams[i].id == sid);
    stream_initialize(i, 0);
}

inline nondet_obtain(n)
{
    if
    :: n = 1;
    :: n = 2
    :: n = 3;
    :: n = 5;
    fi
}

proctype Client(chan conn)
{
    int sid;
    byte indx;
    byte frame, last_frame;

end:
    do
    :: server?RST(indx, sid, 0, 0) -> {
        printf("client: RESET received: %d, %d\n", indx, sid);
        assert(sid > 0);
        assert(indx >= 0 && indx < MAX_STREAMS);
        assert(streams[indx].id == sid);
        assert(streams[indx].state != STATE_IDLE);
      atomic {
        streams[indx].state = STATE_CLOSED;
        stream_reset(indx, sid);
        streams_in_use--;   
      }
    }

    :: server?GOAWAY(0, 0, 0, 0) -> {
        printf("client: GOAWAY received\n");
    }

    :: server?DATA(indx, sid, frame, last_frame) -> {
        assert(sid > 0);
        assert(indx >= 0 && indx < MAX_STREAMS);
        assert(frame > 0 && frame <= last_frame)
        assert(streams[indx].id == sid);
        assert(streams[indx].prev_frame + 1 == frame);
        assert(streams[indx].state == STATE_OPEN || 
               streams[indx].state == STATE_HALF_CLOSED_LOCAL);

        printf("client: DATA received\n");
        if 
        :: (frame == last_frame) -> {
            printf("client:           last frame\ns")
        }
        :: else -> skip;
        fi
        streams[indx].prev_frame = frame;
    }

    :: server?STATUS(indx, sid, 200, 0) -> {
        assert(sid > 0);
        assert(indx > 0 && indx < MAX_STREAMS);
        assert(streams[indx].prev_frame == streams[indx].final_frame)
        assert(streams[indx].id == sid);
        streams[indx].state = STATE_CLOSED;
        stream_reset(indx, sid);
    }

    :: (last_stream_id < 251 && streams_in_use < MAX_STREAMS) -> {
        next_stream_id(indx, sid)
        if
        :: (sid > 0) -> {
            stream_initialize(indx, sid);
            client!GET(indx, sid, 0, 0);
            streams[indx].state = STATE_HALF_CLOSED_LOCAL;
            printf("client: GET sent - %d\n", streams_in_use)
        }
        fi
    }
    
    :: (last_stream_id > 250 && streams_in_use == 0) -> {
        client!GOAWAY(0, 0, 0, 0);
        break;
    }
    od
}

proctype Server(chan conn)
{
    byte indx;
    int sid;
    byte frame, data_frames;

end:
    do
    :: client?GET(indx, sid, 0, 0);
       nondet_obtain(data_frames)
       assert(data_frames >= 1)
       frame = 0
       do
       :: (frame < data_frames) -> {
           frame++
           server!DATA(indx, sid, frame, data_frames);
       }
       :: (frame == data_frames) -> break;
       od

       server!RST(indx, sid, 0, 0);

    :: client?GOAWAY(0, 0, 0, 0) -> break;
    od
}


active proctype main()
{
    chan conn; // = [2] of {mtype, byte, int, byte, byte};

    run Client(conn);
    run Server(conn);
}
