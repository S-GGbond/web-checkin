"""Trae 登录回调服务器的回归测试。

历史问题：本地回调 HTTPServer 从未调用 serve_forever，且回调 handler 的 session
从未绑定到具体会话，导致浏览器回跳 http://127.0.0.1:<port>/authorize 时无应答，
Trae 授权页会一直停在“认证中”。
"""

from __future__ import annotations

import threading
import unittest
import urllib.error
import urllib.request
from http.server import HTTPServer

from trae_tool import _make_callback_handler


class TraeLoginCallbackTests(unittest.TestCase):
    def test_callback_records_query_sets_event_and_rejects_other_paths(self) -> None:
        session: dict = {"event": threading.Event(), "search": None}
        server = HTTPServer(("127.0.0.1", 0), _make_callback_handler(session))
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/authorize?code=ABC&state=xyz", timeout=5
            ) as response:
                body = response.read().decode("utf-8", "replace")
            self.assertEqual(response.status, 200)
            self.assertIn("登录成功", body)

            self.assertTrue(session["event"].wait(1), "回调应设置登录事件")
            self.assertEqual(session["search"], "code=ABC&state=xyz")

            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/other", timeout=5)
            self.assertEqual(ctx.exception.code, 404)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
