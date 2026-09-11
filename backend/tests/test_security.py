import unittest

from runtime.security import authenticated


class SecurityTests(unittest.TestCase):
    def test_accepts_only_loopback_without_browser_origin(self):
        token = "x" * 32
        self.assertTrue(authenticated({"host": "127.0.0.1:8765", "authorization": "Bearer " + token}, token))
        self.assertFalse(authenticated({"host": "192.168.1.5:8765", "authorization": "Bearer " + token}, token))
        self.assertFalse(authenticated({"host": "localhost:8765", "origin": "http://evil.test", "authorization": "Bearer " + token}, token))
        self.assertTrue(authenticated({"host": "localhost:8765", "origin": "http://localhost", "authorization": "Bearer " + token}, token, allow_origin=True))
        self.assertFalse(authenticated({"host": "localhost:8765", "authorization": "Bearer wrong"}, token))


if __name__ == "__main__":
    unittest.main()
