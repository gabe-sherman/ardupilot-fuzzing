#!/usr/bin/env python3
#
# Writes the seed corpus for fuzz_handle_message. Each seed is a sequence of
# MAVLink messages in the harness's record format (see the harness header):
#   u8 sysid, u8 compid, u24 msgid (LE), u8 len, payload
# Payloads come from pymavlink, so field layout and MAVLink2 zero-trimming
# match what a real GCS sends.
#
# Usage: $AP_FUZZ_ROOT/venv/bin/python fuzz/make_seeds.py
#
import os
import struct
import sys

from pymavlink.dialects.v20 import ardupilotmega as m

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "corpus", "fuzz_handle_message")
GCS_SYSID, GCS_COMPID = 255, 190  # MAV_GCS_SYSID default, MissionPlanner compid
TS, TC = 1, 1                     # the vehicle

mav = m.MAVLink(None, srcSystem=GCS_SYSID, srcComponent=GCS_COMPID)


def record(msg, sysid=GCS_SYSID, compid=GCS_COMPID):
    frame = msg.pack(mav)
    payload = frame[10:10 + frame[1]]  # MAVLink2 header is 10 bytes
    msgid = msg.get_msgId()
    return struct.pack("<BBHBB", sysid, compid, msgid & 0xFFFF, msgid >> 16,
                       len(payload)) + payload


def heartbeat():
    return m.MAVLink_heartbeat_message(m.MAV_TYPE_GCS, m.MAV_AUTOPILOT_INVALID,
                                       0, 0, 0, 3)


def cmd_long(cmd, *params):
    p = list(params) + [0] * (7 - len(params))
    return m.MAVLink_command_long_message(TS, TC, cmd, 0, *p)


def cmd_int(cmd, frame=m.MAV_FRAME_GLOBAL_RELATIVE_ALT_INT, p1=0, p2=0, p3=0,
            p4=0, x=0, y=0, z=0):
    return m.MAVLink_command_int_message(TS, TC, frame, cmd, 0, 0,
                                         p1, p2, p3, p4, x, y, z)


GUIDED = 4
LAT, LNG = int(-35.3632621 * 1e7), int(149.1652374 * 1e7)  # SITL default home


def item(seq, cmd, mission_type=m.MAV_MISSION_TYPE_MISSION, p1=0, x=LAT, y=LNG,
         z=10, frame=m.MAV_FRAME_GLOBAL_RELATIVE_ALT_INT):
    return m.MAVLink_mission_item_int_message(TS, TC, seq, frame, cmd, 0, 1,
                                              p1, 0, 0, 0, x, y, z,
                                              mission_type)


def upload(mission_type, items):
    return ([m.MAVLink_mission_count_message(TS, TC, len(items), mission_type)]
            + items)


def ftp(opcode, data=b"", session=0, offset=0, seq=0):
    # seq u16, session, opcode, size, req_opcode, burst_complete, padding,
    # offset u32, data
    hdr = struct.pack("<HBBBBBBI", seq, session, opcode, len(data), 0, 0, 0,
                      offset)
    payload = list(hdr + data) + [0] * (251 - len(hdr) - len(data))
    return m.MAVLink_file_transfer_protocol_message(0, TS, TC, payload)


ARM = cmd_long(m.MAV_CMD_COMPONENT_ARM_DISARM, 1)
SET_GUIDED = cmd_long(m.MAV_CMD_DO_SET_MODE,
                      m.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED, GUIDED)

SEEDS = {
    "heartbeat": [heartbeat()],
    "arm": [heartbeat(), ARM],
    "guided_takeoff": [heartbeat(), SET_GUIDED, ARM,
                       cmd_long(m.MAV_CMD_NAV_TAKEOFF, 0, 0, 0, 0, 0, 0, 10)],
    "guided_reposition": [heartbeat(), SET_GUIDED, ARM,
                          cmd_long(m.MAV_CMD_NAV_TAKEOFF, 0, 0, 0, 0, 0, 0, 10),
                          cmd_int(m.MAV_CMD_DO_REPOSITION, x=LAT + 1000,
                                  y=LNG + 1000, z=20),
                          m.MAVLink_set_position_target_local_ned_message(
                              0, TS, TC, m.MAV_FRAME_LOCAL_NED, 0b110111111000,
                              5, 5, -10, 0, 0, 0, 0, 0, 0, 0, 0)],
    "params": [m.MAVLink_param_request_list_message(TS, TC),
               m.MAVLink_param_request_read_message(TS, TC, b"WPNAV_SPEED", -1),
               m.MAVLink_param_set_message(TS, TC, b"WPNAV_SPEED", 750,
                                           m.MAV_PARAM_TYPE_REAL32)],
    "mission_upload": upload(m.MAV_MISSION_TYPE_MISSION, [
        item(0, m.MAV_CMD_NAV_WAYPOINT, z=0),
        item(1, m.MAV_CMD_NAV_TAKEOFF),
        item(2, m.MAV_CMD_NAV_WAYPOINT, x=LAT + 2000, y=LNG + 2000),
        item(3, m.MAV_CMD_NAV_RETURN_TO_LAUNCH, x=0, y=0, z=0),
    ]) + [m.MAVLink_mission_request_list_message(TS, TC, 0)],
    "fence_upload": upload(m.MAV_MISSION_TYPE_FENCE, [
        item(i, m.MAV_CMD_NAV_FENCE_POLYGON_VERTEX_INCLUSION,
             m.MAV_MISSION_TYPE_FENCE, p1=4, x=LAT + dx, y=LNG + dy,
             z=0, frame=m.MAV_FRAME_GLOBAL)
        for i, (dx, dy) in enumerate([(-5000, -5000), (-5000, 5000),
                                      (5000, 5000), (5000, -5000)])
    ] + [item(4, m.MAV_CMD_NAV_FENCE_CIRCLE_EXCLUSION, m.MAV_MISSION_TYPE_FENCE,
              p1=50, z=0, frame=m.MAV_FRAME_GLOBAL)]),
    "rally_upload": upload(m.MAV_MISSION_TYPE_RALLY, [
        item(0, m.MAV_CMD_NAV_RALLY_POINT, m.MAV_MISSION_TYPE_RALLY,
             x=LAT + 500, y=LNG + 500, z=30),
    ]),
    "ftp": [ftp(3, b"/"),                     # ListDirectory
            ftp(4, b"@PARAM/param.pck", seq=1),  # OpenFileRO
            ftp(5, session=0, seq=2),           # ReadFile
            ftp(1, seq=3)],                     # TerminateSession
    "rc_override": [heartbeat(),
                    m.MAVLink_rc_channels_override_message(
                        TS, TC, 1500, 1500, 1000, 1500, 1800, 0, 0, 0),
                    m.MAVLink_manual_control_message(TS, 0, 0, 500, 0, 0)],
    "origin_and_home": [m.MAVLink_set_gps_global_origin_message(TS, LAT, LNG, 584000, 0),
                        cmd_int(m.MAV_CMD_DO_SET_HOME, z=0, x=LAT, y=LNG)],
    "command_int_fence": [cmd_int(m.MAV_CMD_DO_FENCE_ENABLE, p1=1)],
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in os.listdir(OUT):
        os.remove(os.path.join(OUT, name))
    for name, msgs in SEEDS.items():
        data = b"".join(record(msg) for msg in msgs)
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(data)
        print(f"{name:20s} {len(msgs):2d} msgs {len(data):5d} bytes")


if __name__ == "__main__":
    sys.exit(main())
