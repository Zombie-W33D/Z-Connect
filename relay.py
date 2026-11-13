#!/usr/bin/env python3
"""Stable local SOCKS5 relay with a switchable upstream.

Apps point at one fixed local endpoint. The relay sends new connections to the
phone tunnel when the mode file says "phone", and to the normal network when it
says "direct". If the phone disappears, a phone-mode connection falls back to
the normal network instead of leaving the app with a dead proxy.

Both TCP CONNECT and UDP ASSOCIATE are supported. UDP in phone mode uses the
gost UDP-over-TCP extension (command 0xF3), so it can cross the adb port
forward, which only carries TCP.
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
UDP_IDLE_TIMEOUT = 300.0
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


def send_reply_addr(sock, reply, host, port):
    address = encode_address(host, port)
    sock.sendall(bytes((5, reply, 0)) + address)


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
    if command not in (1, 3):
        send_reply(sock, 7)  # command not supported
        raise ValueError("only CONNECT and UDP ASSOCIATE are supported")

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
    return command, address_type, raw_address, host, port


def upstream_request(address_type, raw_address, port):
    if address_type == 3:
        raw_address = bytes((len(raw_address),)) + raw_address
    return (
        b"\x05\x01\x00"
        + bytes((address_type,))
        + raw_address
        + struct.pack("!H", port)
    )


def encode_address(host, port):
    try:
        packed = socket.inet_pton(socket.AF_INET, host)
        return b"\x01" + packed + struct.pack("!H", port)
    except OSError:
        pass
    try:
        packed = socket.inet_pton(socket.AF_INET6, host)
        return b"\x04" + packed + struct.pack("!H", port)
    except OSError:
        pass
    encoded = host.encode("utf-8")
    return b"\x03" + bytes((len(encoded),)) + encoded + struct.pack("!H", port)


def parse_udp_datagram(data):
    if len(data) < 4 or data[0] != 0 or data[1] != 0:
        return None
    if data[2] != 0:  # fragmented UDP is not supported
        return None
    address_type = data[3]
    offset = 4
    if address_type == 1:
        if len(data) < offset + 4 + 2:
            return None
        host = socket.inet_ntoa(data[offset : offset + 4])
        offset += 4
    elif address_type == 3:
        if len(data) < offset + 1:
            return None
        length = data[offset]
        offset += 1
        if len(data) < offset + length + 2:
            return None
        host = data[offset : offset + length].decode("utf-8", "replace")
        offset += length
    elif address_type == 4:
        if len(data) < offset + 16 + 2:
            return None
        host = socket.inet_ntop(socket.AF_INET6, data[offset : offset + 16])
        offset += 16
    else:
        return None
    port = struct.unpack("!H", data[offset : offset + 2])[0]
    offset += 2
    return host, port, data[offset:]


def build_udp_datagram(host, port, payload):
    return b"\x00\x00\x00" + encode_address(host, port) + payload


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


def socks5_handshake(sock):
    sock.sendall(b"\x05\x01\x00")
    if recv_exact(sock, 2) != b"\x05\x00":
        raise OSError("phone SOCKS5 server rejected no-auth")


def read_socks5_reply(sock):
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


def connect_phone(upstream_host, upstream_port, request, timeout=2.0):
    sock = socket.create_connection((upstream_host, upstream_port), timeout=timeout)
    sock.settimeout(timeout)
    try:
        socks5_handshake(sock)
        sock.sendall(request)
        read_socks5_reply(sock)
        sock.settimeout(None)
        return sock
    except Exception:
        sock.close()
        raise


def open_phone_udp_tunnel(upstream_host, upstream_port, timeout=2.0):
    """Open a gost UDP-over-TCP tunnel (SOCKS5 command 0xF3)."""
    sock = socket.create_connection((upstream_host, upstream_port), timeout=timeout)
    sock.settimeout(timeout)
    try:
        socks5_handshake(sock)
        # 0xF3, reserved, IPv4 0.0.0.0:0. gost binds an ephemeral UDP socket.
        sock.sendall(b"\x05\xf3\x00\x01" + b"\x00" * 4 + b"\x00\x00")
        read_socks5_reply(sock)
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


class UdpSession:
    """One SOCKS5 UDP association.

    The route is chosen once, when the association starts. Existing UDP
    associations keep their route, just like existing TCP connections. If the
    phone tunnel fails, the association falls back to direct (unless fallback
    is disabled), so a dropped phone does not silently black-hole UDP.
    """

    def __init__(self, args, mode):
        self.args = args
        self.mode = mode
        self.lock = threading.Lock()
        self.closed = threading.Event()
        self.client_address = None
        self.client_socket = None
        self.phone = None
        self.direct_sockets = {}
        self.direct_threads = []
        self.last_activity = time.monotonic()

    def set_client(self, client_socket):
        self.client_socket = client_socket

    def send_to_client(self, host, port, payload):
        if self.client_address is None or self.client_socket is None:
            return
        try:
            self.client_socket.sendto(
                build_udp_datagram(host, port, payload), self.client_address
            )
        except OSError:
            self.closed.set()

    def start_phone(self):
        try:
            self.phone = open_phone_udp_tunnel(
                self.args.upstream_host, self.args.upstream_port
            )
        except OSError as error:
            log_phone_error("phone UDP upstream unavailable (%s); using direct" % error)
            self.phone = None
            if not self.args.fallback_direct:
                self.closed.set()
                return False
            self.mode = "direct"
            return True

        thread = threading.Thread(target=self.phone_reader, daemon=True)
        thread.start()
        return True

    def phone_reader(self):
        sock = self.phone
        try:
            while not self.closed.is_set():
                length = struct.unpack("!H", recv_exact(sock, 2))[0]
                recv_exact(sock, 1)  # FRAG
                address_type = recv_exact(sock, 1)[0]
                if address_type == 1:
                    host = socket.inet_ntoa(recv_exact(sock, 4))
                elif address_type == 3:
                    size = recv_exact(sock, 1)[0]
                    host = recv_exact(sock, size).decode("utf-8", "replace")
                elif address_type == 4:
                    host = socket.inet_ntop(socket.AF_INET6, recv_exact(sock, 16))
                else:
                    raise OSError("unsupported UDP tunnel address type")
                port = struct.unpack("!H", recv_exact(sock, 2))[0]
                payload = recv_exact(sock, length)
                self.send_to_client(host, port, payload)
        except (OSError, ConnectionError):
            if not self.closed.is_set():
                log_phone_error("phone UDP tunnel closed; using direct")
                with self.lock:
                    if self.phone is sock:
                        self.phone = None
                        try:
                            sock.close()
                        except OSError:
                            pass
                        if self.args.fallback_direct:
                            self.mode = "direct"
                        else:
                            self.closed.set()

    def direct_socket(self, family):
        sock = self.direct_sockets.get(family)
        if sock is not None:
            return sock
        sock = socket.socket(family, socket.SOCK_DGRAM)
        sock.settimeout(0.5)
        self.direct_sockets[family] = sock
        thread = threading.Thread(
            target=self.direct_reader, args=(sock, family), daemon=True
        )
        thread.start()
        self.direct_threads.append(thread)
        return sock

    def direct_reader(self, sock, family):
        try:
            while not self.closed.is_set():
                try:
                    payload, address = sock.recvfrom(BUFSIZE)
                except socket.timeout:
                    continue
                if family == socket.AF_INET6:
                    host, port = address[0], address[1]
                else:
                    host, port = address[0], address[1]
                self.send_to_client(host, port, payload)
        except OSError:
            pass

    def send_direct(self, host, port, payload):
        try:
            infos = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)
        except OSError as error:
            log("UDP resolve failed for %s:%s: %s" % (host, port, error))
            return
        for family, _socktype, _proto, _canonname, sockaddr in infos:
            sock = self.direct_socket(family)
            try:
                sock.sendto(payload, sockaddr)
                return
            except OSError:
                continue

    def send(self, host, port, payload):
        self.last_activity = time.monotonic()
        with self.lock:
            mode = self.mode
            phone = self.phone
        if mode == "phone" and phone is not None:
            frame = (
                struct.pack("!H", len(payload))
                + b"\x00"
                + encode_address(host, port)
                + payload
            )
            try:
                with self.lock:
                    phone.sendall(frame)
                return
            except OSError as error:
                log_phone_error("phone UDP write failed (%s); using direct" % error)
                with self.lock:
                    if self.phone is phone:
                        self.phone = None
                        try:
                            phone.close()
                        except OSError:
                            pass
                        if self.args.fallback_direct:
                            self.mode = "direct"
                        else:
                            self.closed.set()
                            return
        self.send_direct(host, port, payload)

    def idle(self):
        return time.monotonic() - self.last_activity > UDP_IDLE_TIMEOUT

    def close(self):
        self.closed.set()
        with self.lock:
            phone = self.phone
            self.phone = None
        if phone is not None:
            try:
                phone.close()
            except OSError:
                pass
        for sock in list(self.direct_sockets.values()):
            try:
                sock.close()
            except OSError:
                pass
        self.direct_sockets.clear()


def watch_control(control, closed):
    try:
        while not closed.is_set():
            if not control.recv(4096):
                break
    except OSError:
        pass
    closed.set()


def handle_udp(client, args, mode, _request):
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", 0))
    bound_host, bound_port = udp.getsockname()
    send_reply_addr(client, 0, bound_host, bound_port)

    session = UdpSession(args, mode)
    session.set_client(udp)
    if mode == "phone" and not session.start_phone():
        udp.close()
        return

    watcher = threading.Thread(target=watch_control, args=(client, session.closed), daemon=True)
    watcher.start()

    try:
        udp.settimeout(0.5)
        while not session.closed.is_set():
            try:
                data, address = udp.recvfrom(BUFSIZE)
            except socket.timeout:
                if session.idle():
                    break
                continue
            except OSError:
                break
            if session.client_address is None:
                session.client_address = address
            elif address != session.client_address:
                continue
            parsed = parse_udp_datagram(data)
            if parsed is None:
                continue
            host, port, payload = parsed
            session.send(host, port, payload)
    finally:
        session.close()
        udp.close()


def handle(client, args):
    try:
        command, address_type, raw_address, host, port = read_request(client)
        mode = read_mode(args.mode_file)

        if command == 3:
            handle_udp(client, args, mode, (address_type, raw_address, host, port))
            return

        request = upstream_request(address_type, raw_address, port)
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
        if str(error) not in (
            "not SOCKS5",
            "only CONNECT and UDP ASSOCIATE are supported",
        ):
            log("client connection failed: %s" % error)
    finally:
        client.close()


def parse_address(value):
    host, separator, port = value.rpartition(":")
    if separator == "" or host == "" or not port.isdigit():
        raise argparse.ArgumentTypeError("expected host:port")
    return host, int(port)


def write_pid_file(path):
    if not path:
        return
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("%d\n" % os.getpid())
    except OSError as error:
        log("could not write pid file %s: %s" % (path, error))


def remove_pid_file(path):
    if not path:
        return
    try:
        with open(path, "r", encoding="utf-8") as handle:
            pid = handle.read().strip()
        if pid == str(os.getpid()):
            os.unlink(path)
    except OSError:
        pass


def main():
    parser = argparse.ArgumentParser(description="Z-Connect stable SOCKS5 relay")
    parser.add_argument("--listen", type=parse_address, default=("127.0.0.1", 1080))
    parser.add_argument("--upstream", type=parse_address, default=("127.0.0.1", 1081))
    parser.add_argument("--mode-file", required=True)
    parser.add_argument("--pid-file", default="")
    parser.add_argument("--no-fallback-direct", action="store_true")
    args = parser.parse_args()

    args.listen_host, args.listen_port = args.listen
    args.upstream_host, args.upstream_port = args.upstream
    args.fallback_direct = not args.no_fallback_direct

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.listen_host, args.listen_port))
    listener.listen(128)
    write_pid_file(args.pid_file)
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
        remove_pid_file(args.pid_file)
        try:
            listener.close()
        finally:
            sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    try:
        while True:
            try:
                client, _address = listener.accept()
            except OSError:
                break
            thread = threading.Thread(target=handle, args=(client, args), daemon=True)
            thread.start()
    finally:
        remove_pid_file(args.pid_file)


if __name__ == "__main__":
    main()
