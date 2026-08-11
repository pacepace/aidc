#!/bin/sh
# Squid healthcheck: verify the proxy answers on port 3128.
# Used by docker-compose healthcheck (and gated on by `aidc create`, which
# hard-fails the session if squid never reports healthy).
#
# Implemented in perl rather than bash. The ubuntu/squid:7.x base is a chiselled
# Rock -- it ships no bash, so the previous `exec 3<>/dev/tcp/127.0.0.1/3128`
# bashism has nothing to run on. perl IS in the base image (squid's own helper
# programs are perl), and IO::Socket::INET is core, so this adds no packages and
# no attack surface to a security-critical sidecar.
#
# Semantics are unchanged from the bash version: connect, send a request line,
# read the first response line, succeed only on an HTTP/ status line. The alarm
# bounds the read -- IO::Socket::INET's Timeout covers connect() only, and a
# squid that accepts the connection then wedges must read as UNHEALTHY, not hang
# until docker's own timeout kills us with an ambiguous result.
set -eu

exec perl -MIO::Socket::INET -e '
    $SIG{ALRM} = sub { exit 1 };
    alarm 3;
    my $sock = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1",
        PeerPort => 3128,
        Proto    => "tcp",
        Timeout  => 3,
    ) or exit 1;
    print $sock "GET / HTTP/1.0\r\n\r\n";
    my $line = <$sock>;
    exit(defined($line) && $line =~ m{^HTTP/} ? 0 : 1);
'
