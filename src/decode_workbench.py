#!/usr/bin/env python3
"""Small scratch decoder for one Stormancer scene-message payload."""

import base64
import json
import quopri

import msgpack

RAW_HEX = "8d02000200da05687b22746f6b656e223a2269366c4259324e7664573530535753705a474679613352686247567a7130467763477870593246306157397572477870646d55744d5330774e5330774d4b5a4a63334e315a5754582f395a6f2f7442714a556241716b563463476c7959585270623237582f395a70416642714a5566737146567a5a584a45595852687851486841414142335a6d5370584e305a574674735463324e5459784d546b334f5463334f4463774d6a59336d4e6b674e4445324f475a6d596a49305a4755794e44566d4f4467774e6a426b4d6a646a4f5455344d4459344e57574270584e305a5746746761647a6447566862576c6b735463324e5459784d546b334f5463334f4463774d6a593367365a77633256315a475c75303032427154574671623349675347396d5a716476634852706232357a67616c6a636d397a6333427359586d427032567559574a735a57544470334e305a574674615753784e7a59314e6a45784f5463354e7a63344e7a41794e6a66582f7a67415463427147315a52312f383441453341616874575559436c6333526c59573341784244685a306346323075305236705556654253726570396761567a644756686262647a6447566862546f334e6a55324d5445354e7a6b334e7a67334d4449324e344b726333526c59573075595842775357544542504361487743355a3246745a565a6c636e4e7062323475593278705a573530566d567963326c76627351504141414143366f784c6a41314c6a41774c6a4131312f38384e6f49516169564776746d6263324e6c626d55364c33426863334e305a574e6f4c577870646d55764c325268636d74305957786c6379397361585a6c4c5445744d4455744d4441764d6a55324e475134596d55744d6d5269596930304f5459334c574932596d49744d4755784e5464685954646d4e6a4e6d4c7a452f4c3246316447686c626e5270593246306233496a595856306147567564476c6a59585276636938774b437370577a4a6c4d446b314e6d55784c546b304d3259744e4745305a5331684d47497a4c5446694f445a6b4f5441324d444135596c3341414b7444623235305a57353056486c775a625a7a6447397962574675593256794c33567a5a584a545a584e7a61573975715556755a484276615735306338436e55324e6c626d564a5a4e6b7a63324e6c626d55364c33426863334e305a574e6f4c577870646d55765a474679613352686247567a4c327870646d55744d5330774e5330774d43396d636d6c6c626d527a70314a7664585270626d66417245526c634778766557316c626e524a5a4e6b6b4d6a55324e475134596d55744d6d5269596930304f5459334c574932596d49744d4755784e5464685954646d4e6a4e6d70315a6c636e4e70623234432d67774b7336452f446968744f3374377938704674544246646d427a464e434372394555554168556b6735733d222c22656e64706f696e7473223a7b2272616b6e6574223a5b2264742d6c6976652e706173737465636867616d65732e636f6d3a3330313030222c2264742d6c6976652d322e706173737465636867616d65732e636f6d3a3330313030225d7d2c22656e6372797074696f6e223a7b22616c676f726974686d223a22616573323536222c226d6f6465223a2247434d222c226b6579223a2246755244437637546757634b655a5c753030324272392f594a3357426f474c49546c6a687a59646d344e6579675436493d222c22746f6b656e223a227842446e4451614a6f79515a533433354365343749644d704a71684f5a464569576f67335c7530303242526f647568573564336261687570386850534761424f6c714b2f674536573065775a7261514d6648757347616c50574c70736b585446436c2f53417635633d227d7d7373696f6e2e557064617465557365724f7074696f6e73a648616e646c650fa84d6574616461746181b673746f726d616e6365722e706c7567696e732e727063a5312e312e3083a44e616d65b74e582e4765744164766572746973656450617274696573a648616e646c6510a84d6574616461746181b673746f726d616e6365722e706c7567696e732e727063a5312e312e3083a44e616d65b2537465616d2e517565727955736572496473a648616e646c6511a84d6574616461746181b673746f726d616e6365722e706c7567696e732e727063a5312e312e3083a44e616d65d921537465616d2e4465636f6465506172747944617461426561726572546f6b656e73a648616e646c6512a84d6574616461746181b673746f726d616e6365722e706c7567696e732e727063a5312e312e3083a44e616d65bf4c6f6361746f722e4765745363656e65436f6e6e656374696f6e546f6b656ea648616e646c6513a84d6574616461746181b673746f726d616e6365722e706c7567696e732e727063a5312e312e30ad6d73677061636b2f617272617900000000000000000000000000000000000000000000000000000000000000000000000000000000000058b299bcb37f0000000000000000000000000000000000000000000000000000487b2069f07f000078b299bcb37f000050b399bcb37f00000000000000000000507f2069f07f000028b499bcb37f000004000000040000000000000000000000a071076cf07f0000009c99bcb37f000004000000050000000100000000000000000000000000000000000000000000000000000000000000c8892069f07f0000e8b199bcb37f00000000000000000000a0b499bcb37f0000000000000000000000000000000000000000000000000000"

def b64decode(value: str) -> bytes:
    return base64.b64decode(value + "=" * (-len(value) % 4))


def unpack_one(data: bytes):
    try:
        return msgpack.unpackb(data, raw=False, strict_map_key=False, timestamp=0), b""
    except msgpack.ExtraData as exc:
        return exc.unpacked, exc.extra


def jsonable(value):
    if isinstance(value, bytes):
        return bytes_info(value)
    if isinstance(value, msgpack.Timestamp):
        return {"timestamp_seconds": value.seconds, "timestamp_nanoseconds": value.nanoseconds}
    if isinstance(value, list):
        return [jsonable(item) for item in value]
    if isinstance(value, dict):
        return {str(key): jsonable(item) for key, item in value.items()}
    return value


def quoted_printable(raw: bytes) -> str:
    return quopri.encodestring(raw, quotetabs=True).decode("ascii")


def bytes_info(raw: bytes) -> dict:
    return {"hex": raw.hex()}


def decode_userdata(raw: bytes) -> dict:
    if len(raw) < 4:
        return bytes_info(raw)

    payload_len = int.from_bytes(raw[:4], "big")
    if payload_len != len(raw) - 4:
        return bytes_info(raw)

    value, tail = unpack_one(raw[4:])
    out = userdata_fields(value)
    if tail:
        out["tail_quoted_printable"] = quoted_printable(tail)
        out["tail_hex"] = tail.hex()
    return out


def userdata_fields(value) -> dict:
    if not isinstance(value, list) or len(value) < 9:
        return {}
    return {
        "login_provider": jsonable(value[0]),
        "user": user_record_fields(value[1]),
        "session_id": bytes_info(value[2]) if isinstance(value[2], bytes) else jsonable(value[2]),
        "identities": jsonable(value[3]),
        "metadata": userdata_metadata(value[4]),
        "expiration": jsonable(value[5]),
        "authenticator_scene": jsonable(value[6]),
        "reserved": jsonable(value[7]),
        "flags": jsonable(value[8]),
    }


def user_record_fields(value) -> dict:
    if not isinstance(value, list) or len(value) < 8:
        return {"raw": jsonable(value)}
    return {
        "user_id": jsonable(value[0]),
        "platforms": jsonable(value[1]),
        "profile": jsonable(value[2]),
        "created": jsonable(value[3]),
        "updated": jsonable(value[4]),
        "metadata": jsonable(value[5]),
        "provider": jsonable(value[6]),
        "reserved": jsonable(value[7]),
    }


def userdata_metadata(value) -> dict:
    if not isinstance(value, dict):
        return {"raw": jsonable(value)}

    out = {}
    for key, item in value.items():
        if isinstance(item, bytes):
            if key == "steam.appId" and len(item) == 4:
                out[key] = {"u32_le": int.from_bytes(item, "little")}
            elif len(item) >= 4 and int.from_bytes(item[:4], "big") == len(item) - 4:
                nested, tail = unpack_one(item[4:])
                out[key] = {"u32be_msgpack": jsonable(nested)}
                if tail:
                    out[key]["tail_quoted_printable"] = quoted_printable(tail)
                    out[key]["tail_hex"] = tail.hex()
            else:
                out[key] = bytes_info(item)
        else:
            out[key] = jsonable(item)
    return out


def main() -> None:
    payload = bytes.fromhex(RAW_HEX)
    json_text, tail = unpack_one(payload[5:])
    decoded = json.loads(json_text)

    token_data, token_sig = decoded["token"].split("-", 1)
    token_msgpack, token_tail = unpack_one(b64decode(token_data))
    token_msgpack["UserData"] = decode_userdata(token_msgpack["UserData"])
    decoded["token_decoded"] = {
        "signature_base64": token_sig,
        "msgpack": jsonable(token_msgpack),
    }
    del decoded["token"]

    print(json.dumps(decoded, indent=2, ensure_ascii=False))
    print("extra_quoted_printable =", repr(quoted_printable(tail)))
    if token_tail:
        print("token_tail_quoted_printable =", repr(quoted_printable(token_tail)))


if __name__ == "__main__":
    main()
