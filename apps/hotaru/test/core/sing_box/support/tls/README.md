# Loopback TLS test fixture

This self-signed certificate and openly committed private key are exclusively for the local HTTP/HTTPS routing tests. They must never be used as application signing credentials, production TLS credentials, or installed in an operating-system trust store. Tests accept only this certificate on the exact fixture address and port; production clients retain normal TLS verification.
