#!/usr/bin/env python3
"""Stable local SOCKS5 relay with a switchable upstream.

Apps point at one fixed local endpoint. The relay sends new connections to the
phone tunnel when the mode file says "phone", and to the normal network when it
says "direct". If the phone disappears, a phone-mode connection falls back to
the normal network instead of leaving the app with a dead proxy.

Only TCP CONNECT is implemented. That is what browsers and ordinary desktop
apps use; UDP ASSOCIATE is rejected.
"""

import argparse
import os
import select
import signal
import socket
import struct
import sys
import threading
import time

BUFSIZE = 65536
PHONE_ERROR_INTERVAL = 10.0
_last_phone_error = 0.0


def log(message):
    print(message, file=sys.stderr, flush=True)


def log_phone_error(message):
    global _last_phone_error
    now = time.monotonic()
    if now - _last_phone_error >= PHONE_ERROR_INTERVAL:
        _last_phone_error = now
        log(message)


def recv_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("unexpected EOF")
        data.extend(chunk)
    return bytes(data)


def read_mode(path, default="direct"):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            mode = handle.read().strip().lower()
    except OSError:
        return default
    return mode if mode in ("phone", "direct") else default


def send_reply(sock, reply):
    # Bound address is intentionally 0.0.0.0:0; clients ignore it for CONNECT.
    sock.sendall(bytes((5, reply, 0, 1, 0, 0, 0, 0, 0, 0)))


def read_request(sock):
    version, method_count = recv_exact(sock, 2)
    if version != 5:
        raise ValueError("not SOCKS5")
    methods = recv_exact(sock, method_count)
    if 0 not in methods:
        sock.sendall(b"\x05\xff")
        raise ValueError("client requires authentication")
    sock.sendall(b"\x05\x00")

    version, command, _reserved, address_type = recv_exact(sock, 4)
    if version != 5:
        raise ValueError("bad request version")
    if command != 1:
        send_reply(sock, 7)  # command not supported
        raise ValueError("only CONNECT is supported")

    if address_type == 1:
        raw_address = recv_exact(sock, 4)
        host = socket.inet_ntoa(raw_address)
    elif address_type == 3:
        length = recv_exact(sock, 1)[0]
        raw_address = recv_exact(sock, length)
        host = raw_address.decode("utf-8", "replace")
    elif address_type == 4:
        raw_address = recv_exact(sock, 16)
        host = socket.inet_ntop(socket.AF_INET6, raw_address)
    else:
        send_reply(sock, 8)  # address type not supported
        raise ValueError("unsupported address type")

    port = struct.unpack("!H", recv_exact(sock, 2))[0]
    return address_type, raw_address, host, port


def upstream_request(address_type, raw_address, port):
    if address_type == 3:
        raw_address = bytes((len(raw_address),)) + raw_address
    return (
        b"\x05\x01\x00"
        + bytes((address_type,))
        + raw_address
        + struct.pack("!H", port)
    )


def connect_direct(host, port):
    last_error = None
    for family, socktype, proto, _canonname, sockaddr in socket.getaddrinfo(
        host, port, type=socket.SOCK_STREAM
    ):
        sock = socket.socket(family, socktype, proto)
        sock.settimeout(10)
        try:
            sock.connect(sockaddr)
            sock.settimeout(None)
            return sock
        except OSError as error:
            last_error = error
            sock.close()
    raise last_error or OSError("could not resolve or connect")


def connect_phone(upstream_host, upstream_port, request, timeout=2.0):
    sock = socket.create_connection((upstream_host, upstream_port), timeout=timeout)
    sock.settimeout(timeout)
    try:
        sock.sendall(b"\x05\x01\x00")
        if recv_exact(sock, 2) != b"\x05\x00":
            raise OSError("phone SOCKS5 server rejected no-auth")
        sock.sendall(request)
        reply = recv_exact(sock, 4)
        if reply[0] != 5 or reply[1] != 0:
            raise OSError("phone SOCKS5 reply %d" % reply[1])
        address_type = reply[3]
        if address_type == 1:
            recv_exact(sock, 4)
        elif address_type == 3:
            recv_exact(sock, recv_exact(sock, 1)[0])
        elif address_type == 4:
            recv_exact(sock, 16)
        else:
            raise OSError("phone returned an unsupported address type")
        recv_exact(sock, 2)
        sock.settimeout(None)
        return sock
    except Exception:
        sock.close()
        raise


def relay(left, right):
    sockets = (left, right)
    try:
        while True:
            readable, _writable, _exceptional = select.select(sockets, (), ())
            for source in readable:
                data = source.recv(BUFSIZE)
                if not data:
                    return
                destination = right if source is left else left
                destination.sendall(data)
    except OSError:
        pass


def handle(client, args):
    try:
        address_type, raw_address, host, port = read_request(client)
        request = upstream_request(address_type, raw_address, port)
        mode = read_mode(args.mode_file)

        remote = None
        if mode == "phone":
            try:
                remote = connect_phone(args.upstream_host, args.upstream_port, request)
            except OSError as error:
                log_phone_error("phone upstream unavailable (%s); using direct" % error)
                if not args.fallback_direct:
                    send_reply(client, 5)  # connection refused
                    return

        if remote is None:
            try:
                remote = connect_direct(host, port)
            except OSError as error:
                log("direct connection to %s:%s failed: %s" % (host, port, error))
                send_reply(client, 5)
                return

        send_reply(client, 0)
        relay(client, remote)
        remote.close()
    except (ConnectionError, ValueError, OSError) as error:
        if str(error) not in ("not SOCKS5", "only CONNECT is supported"):
            log("client connection failed: %s" % error)
    finally:
        client.close()


def parse_address(value):
    host, separator, port = value.rpartition(":")
    if separator == "" or host == "" or not port.isdigit():
        raise argparse.ArgumentTypeError("expected host:port")
    return host, int(port)


def main():
    parser = argparse.ArgumentParser(description="Z-Connect stable SOCKS5 relay")
    parser.add_argument("--listen", type=parse_address, default=("127.0.0.1", 1080))
    parser.add_argument("--upstream", type=parse_address, default=("127.0.0.1", 1081))
    parser.add_argument("--mode-file", required=True)
    parser.add_argument("--no-fallback-direct", action="store_true")
    args = parser.parse_args()

    args.listen_host, args.listen_port = args.listen
    args.upstream_host, args.upstream_port = args.upstream
    args.fallback_direct = not args.no_fallback_direct

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.listen_host, args.listen_port))
    listener.listen(128)
    log(
        "relay listening on %s:%d; phone upstream %s:%d; mode file %s"
        % (
            args.listen_host,
            args.listen_port,
            args.upstream_host,
            args.upstream_port,
            args.mode_file,
        )
    )

    def stop(_signum, _frame):
        try:
            listener.close()
        finally:
            sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    while True:
        try:
            client, _address = listener.accept()
        except OSError:
            break
        thread = threading.Thread(target=handle, args=(client, args), daemon=True)
        thread.start()


if __name__ == "__main__":
    main()
