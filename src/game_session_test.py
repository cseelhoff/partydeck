"""Captured-wire regression checks for the live GameSession handlers."""

import unittest

import predict
import raknet as R
import raknet_samples
import scenes
from two_peer_merge import CaptureSock, _mk_conn, _reset_globals


class GameSessionTests(unittest.TestCase):
    def setUp(self):
        _reset_globals()
        self.sock = CaptureSock()
        self.peers = [
            _mk_conn(self.sock, ("127.0.0.1", 51001), "host", "Host", 76561190000000001),
            _mk_conn(self.sock, ("127.0.0.1", 51002), "joiner", "Joiner", 76561190000000002),
        ]
        self.party = R.Party("11111111-1111-4111-8111-111111111111", self.peers[0])
        self.party.add_member(self.peers[1])
        self.gs = R.GameSession("22222222-2222-4222-8222-222222222222", self.party)
        R.GAMESESSIONS[self.gs.guid] = self.gs
        for peer, handle in zip(self.peers, (180, 188)):
            routes = scenes.SceneRoutes(
                "gamesession", scenes.gamesession_infos(self.gs.guid),
                scenes.gamesession_connect(self.gs.guid, handle),
            )
            peer.scene_bindings[handle] = R.SceneBinding(
                "gamesession", self.gs.scene_id, routes, self.gs.guid,
            )

    def test_player_update_matches_every_captured_body(self):
        for sample in raknet_samples.samples("gamesession/player.update"):
            with self.subTest(body=sample["hex"]):
                body = bytes.fromhex(sample["hex"])
                length = body[2]
                self.peers[0].user_id = body[3:3 + length].decode("utf-8")
                status = body[3 + length]
                R.broadcast_player_update(self.sock, self.gs, self.peers[0], status)
                datagrams = self.sock.drain()
                self.assertEqual(len(datagrams), 2)
                for address, datagram in datagrams:
                    messages = R.parse_messages_ex(datagram, 4)
                    self.assertEqual(len(messages), 1)
                    self.assertEqual(messages[0]["payload"][3:], body)
                    recipient = next(peer for peer in self.peers if (peer.ip, peer.port) == address)
                    binding = recipient.binding_for("gamesession", self.gs.guid)
                    self.assertEqual(messages[0]["payload"][0], binding.sr.handle)

    def test_data_oriented_wire_entry_matches_player_update_capture(self):
        world = predict.new_world()
        addresses = [("127.0.0.1", 52001), ("127.0.0.1", 52002)]
        handles = [180, 188]
        sample = raknet_samples.require("gamesession/player.update")
        expected = bytes.fromhex(sample["hex"])
        guid = self.gs.guid
        peers = []
        for address, handle in zip(addresses, handles):
            predict.predict(world, address, bytes([R.ID_OPEN_CONNECTION_REQUEST_1]) + R.MAGIC + b"\x06")
            peer = world["conns"][address]
            routes = scenes.SceneRoutes(
                "gamesession", scenes.gamesession_infos(guid),
                scenes.gamesession_connect(guid, handle),
            )
            peer["bindings"][handle] = {
                "kind": "gamesession", "ref": guid,
                "routes": {
                    "handle": handle,
                    "server_recv_rev": routes.server_recv_rev,
                    "client_recv": routes.client_recv,
                    "rpc_next": routes.rpc_next,
                    "rpc_completed": routes.rpc_completed,
                },
            }
            peers.append(peer)
        peers[0]["user_id"] = expected[3:35].decode("utf-8")
        world["gamesessions"][guid] = {"guid": guid, "members": peers, "ready": set()}
        route = next(
            route for route, name in peers[0]["bindings"][180]["routes"]["server_recv_rev"].items()
            if name == "GameSession.GetP2PToken"
        )
        request = bytes([180]) + route.to_bytes(2, "little") + b"\x01\x00\x01"
        datagram = R.make_data_datagram(
            0, R.make_message(R.RELIABLE_ORDERED, request, reliable_num=0, ordering_index=0),
        )
        emitted = predict.predict(world, addresses[0], datagram)
        updates = []
        for address, data in emitted:
            if data[0] & 0x60:
                continue
            for message in R.parse_messages_ex(data, 4):
                payload = message["payload"]
                index = addresses.index(address)
                binding = peers[index]["bindings"][handles[index]]["routes"]
                if payload[:3] == bytes([handles[index]]) + binding["client_recv"]["player.update"].to_bytes(2, "little"):
                    updates.append((address, payload[3:]))
        self.assertCountEqual(updates, [(address, expected) for address in addresses])

    def test_party_notifications_keep_fixed_width_rpc_ids_across_version_thresholds(self):
        cases = {
            127: "7f007f",
            128: "8000cc80",
            255: "ff00ccff",
            256: "0001cd0100",
            65535: "ffffcdffff",
            65536: "0000ce00010000",
        }
        for version, prefix in cases.items():
            with self.subTest(version=version):
                world = predict.new_world()
                address = ("127.0.0.1", 53001)
                predict.predict(world, address, bytes([R.ID_OPEN_CONNECTION_REQUEST_1]) + R.MAGIC + b"\x06")
                peer = world["conns"][address]
                guid = self.party.guid
                routes = scenes.SceneRoutes(
                    "party", scenes.party_infos(guid), scenes.party_connect(guid, 180),
                )
                peer["bindings"][180] = {
                    "kind": "party", "ref": guid,
                    "routes": {
                        "handle": 180,
                        "server_recv_rev": routes.server_recv_rev,
                        "client_recv": routes.client_recv,
                        "rpc_next": routes.rpc_next,
                        "rpc_completed": routes.rpc_completed,
                    },
                }
                world["parties"][guid] = {
                    "guid": guid, "members": [peer], "version": version - 1,
                    "custom_data": "{}", "gs_guid": None,
                }
                route = next(
                    route for route, name in routes.server_recv_rev.items()
                    if name == "party.updatepartysettings"
                )
                request = bytes([180]) + route.to_bytes(2, "little") + b"\x01\x00"
                datagram = R.make_data_datagram(
                    0, R.make_message(R.RELIABLE_ORDERED, request, reliable_num=0, ordering_index=0),
                )
                notifications = []
                for _, data in predict.predict(world, address, datagram):
                    if data[0] & 0x60:
                        continue
                    for message in R.parse_messages_ex(data, 4):
                        payload = message["payload"]
                        header = bytes([180]) + routes.client_recv["party.settingsUpdated"].to_bytes(2, "little")
                        if payload[:3] == header:
                            notifications.append(payload[3:])
                self.assertEqual(len(notifications), 1)
                expected_prefix = bytes.fromhex(prefix)
                self.assertEqual(notifications[0][:len(expected_prefix)], expected_prefix)


if __name__ == "__main__":
    unittest.main()
