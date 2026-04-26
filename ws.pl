#!/usr/bin/env perl
# ws.pl -- WebSocket library + line-oriented stdin/stdout bridge.
#
# As a module:
#   require 'ws.pl';
#   my $ws = WS->connect($host, $port, $path);
#   $ws->set_nonblocking;
#   ... use IO::Select on $ws->sock; call $ws->pump and $ws->try_recv ...
#
# As a program:
#   perl ws.pl ws://host:port/path
#   Each line on stdin is sent as one text frame.
#   Each text/binary message received is printed as one stdout line, with
#   embedded newlines escaped (\\, \n, \r) so the framing stays line-oriented.

package WS;
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Fcntl         qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno         qw(EAGAIN EWOULDBLOCK);
use Digest::SHA   qw(sha1);
use MIME::Base64  qw(encode_base64);

# --- Handshake (blocking, runs once before going non-blocking) -----------

sub connect {
    my ($class, $host, $port, $path) = @_;

    my $sock = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Proto    => 'tcp',
    ) or die "tcp connect: $!";

    my $key_bytes = join '', map { chr(int rand 256) } 1..16;
    my $key       = encode_base64($key_bytes, '');

    my $req = join("\r\n",
        "GET $path HTTP/1.1",
        "Host: $host:$port",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: $key",
        "Sec-WebSocket-Version: 13",
        "", "",
    );
    syswrite($sock, $req) == length($req) or die "handshake write: $!";

    my $resp = '';
    while ($resp !~ /\r\n\r\n/) {
        sysread($sock, my $buf, 4096) or die "handshake read: $!";
        $resp .= $buf;
    }

    $resp =~ m{^HTTP/1\.1 101} or die "expected 101, got: $resp";

    my $magic    = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
    my $expected = encode_base64(sha1($key . $magic), '');
    $resp =~ /Sec-WebSocket-Accept:\s*\Q$expected\E/i
        or die "Sec-WebSocket-Accept mismatch";

    return bless {
        sock    => $sock,
        rbuf    => '',
        msg_op  => undef,
        msg_buf => '',
        closed  => 0,
    }, $class;
}

sub sock   { $_[0]->{sock} }
sub closed { $_[0]->{closed} }

sub set_nonblocking {
    my $self  = shift;
    my $flags = fcntl($self->{sock}, F_GETFL, 0) or die "fcntl GETFL: $!";
    fcntl($self->{sock}, F_SETFL, $flags | O_NONBLOCK) or die "fcntl SETFL: $!";
    return $self;
}

# --- Reading: pump bytes, parse frames out of the buffer -----------------

# One sysread into rbuf. Returns bytes read, 0 on would-block, -1 on EOF.
sub pump {
    my $self = shift;
    my $got  = sysread($self->{sock}, my $buf, 65536);
    if (!defined $got) {
        return 0 if $!{EAGAIN} || $!{EWOULDBLOCK};
        die "read: $!";
    }
    if ($got == 0) {
        $self->{closed} = 1;
        return -1;
    }
    $self->{rbuf} .= $buf;
    return $got;
}

sub _try_parse_frame {
    my $self = shift;
    my $buf  = \$self->{rbuf};
    return undef if length($$buf) < 2;

    my ($b1, $b2) = unpack 'CC', substr($$buf, 0, 2);
    my $masked = $b2 & 0x80;
    my $len    = $b2 & 0x7F;
    my $off    = 2;

    if ($len == 126) {
        return undef if length($$buf) < $off + 2;
        $len = unpack 'n', substr($$buf, $off, 2);
        $off += 2;
    } elsif ($len == 127) {
        return undef if length($$buf) < $off + 8;
        my ($hi, $lo) = unpack 'NN', substr($$buf, $off, 8);
        $len = $hi * 2**32 + $lo;
        $off += 8;
    }

    my $mask = '';
    if ($masked) {
        return undef if length($$buf) < $off + 4;
        $mask = substr($$buf, $off, 4);
        $off += 4;
    }

    return undef if length($$buf) < $off + $len;
    my $payload = $len ? substr($$buf, $off, $len) : '';
    substr($$buf, 0, $off + $len, '');

    if ($masked) {
        my @m = unpack 'C4', $mask;
        my @p = unpack 'C*', $payload;
        $p[$_] ^= $m[$_ % 4] for 0..$#p;
        $payload = pack 'C*', @p;
    }

    return { fin => !!($b1 & 0x80), opcode => $b1 & 0x0F, payload => $payload };
}

sub _process_frame {
    my ($self, $f) = @_;
    my $op = $f->{opcode};

    if    ($op == 0x9) { $self->_write_frame(0xA, $f->{payload}); return undef }  # ping
    elsif ($op == 0xA) { return undef }                                            # pong
    elsif ($op == 0x8) {                                                           # close
        $self->_write_frame(0x8, $f->{payload}) unless $self->{closed};
        $self->{closed} = 1;
        CORE::close $self->{sock};
        return { closed => 1 };
    }
    elsif ($op == 0x1 || $op == 0x2) {
        die "nested data frame" if defined $self->{msg_op};
        return { opcode => $op, payload => $f->{payload} } if $f->{fin};
        $self->{msg_op}  = $op;
        $self->{msg_buf} = $f->{payload};
        return undef;
    }
    elsif ($op == 0x0) {
        die "stray continuation" unless defined $self->{msg_op};
        $self->{msg_buf} .= $f->{payload};
        if ($f->{fin}) {
            my $msg = { opcode => $self->{msg_op}, payload => $self->{msg_buf} };
            $self->{msg_op}  = undef;
            $self->{msg_buf} = '';
            return $msg;
        }
        return undef;
    }
    else { die sprintf "unknown opcode 0x%X", $op }
}

# Pull as many complete messages out of rbuf as currently possible.
# Pair with pump() under select.
sub try_recv {
    my $self = shift;
    while (1) {
        my $f = $self->_try_parse_frame or return undef;
        my $msg = $self->_process_frame($f) or next;
        return undef if $msg->{closed};
        return $msg;
    }
}

# --- Writing: one message in, one masked frame out -----------------------

sub _write_frame {
    my ($self, $opcode, $payload) = @_;
    my $len = length $payload;

    my $hdr;
    if    ($len < 126)   { $hdr = pack 'CC',   0x80|$opcode, 0x80|$len }
    elsif ($len < 65536) { $hdr = pack 'CCn',  0x80|$opcode, 0x80|126, $len }
    else {
        $hdr = pack 'CCNN', 0x80|$opcode, 0x80|127,
                            int($len / 2**32), $len % 2**32;
    }

    my $mask = join '', map { chr(int rand 256) } 1..4;
    my @m = unpack 'C4', $mask;
    my @p = unpack 'C*', $payload;
    $p[$_] ^= $m[$_ % 4] for 0..$#p;

    my $frame = $hdr . $mask . pack('C*', @p);
    my $off = 0;
    while ($off < length $frame) {
        my $n = syswrite($self->{sock}, $frame, length($frame) - $off, $off);
        if (!defined $n) {
            if ($!{EAGAIN} || $!{EWOULDBLOCK}) {
                IO::Select->new($self->{sock})->can_write;
                next;
            }
            die "write: $!";
        }
        $off += $n;
    }
}

sub send_text   { $_[0]->_write_frame(0x1, $_[1]) }
sub send_binary { $_[0]->_write_frame(0x2, $_[1]) }

sub close {
    my ($self, $code, $reason) = @_;
    return if $self->{closed};
    $code //= 1000; $reason //= '';
    $self->_write_frame(0x8, pack('n', $code) . $reason);
    $self->{closed} = 1;
    CORE::close $self->{sock};
}

# --- Bridge: stdin <-> WebSocket <-> stdout ------------------------------
#
# Run only when invoked as a script, not when require'd as a library.

unless (caller) {
    package main;

    my $url = shift @ARGV or die "usage: $0 ws://host:port/path\n";
    my ($host, $port, $path) = $url =~ m{^ws://([^:/]+):(\d+)(/.*)?$}
        or die "can't parse $url\n";
    $path //= '/';

    my $ws = WS->connect($host, $port, $path);
    $ws->set_nonblocking;

    STDOUT->autoflush(1);
    STDERR->autoflush(1);
    warn "connected: $url\n";

    my $sel        = IO::Select->new($ws->sock, \*STDIN);
    my $stdin_open = 1;
    my $linger     = 1.0;  # seconds to keep draining after stdin EOF

    my $escape_nl = sub {
        my $s = shift;
        $s =~ s/\\/\\\\/g;
        $s =~ s/\n/\\n/g;
        $s =~ s/\r/\\r/g;
        return $s;
    };

    while (!$ws->closed) {
        my $timeout = $stdin_open ? undef : $linger;
        my @ready   = $sel->can_read($timeout);
        if (!@ready) {
            last unless $stdin_open;   # idle past linger after stdin EOF
            next;
        }
        for my $fh (@ready) {
            if ($fh == $ws->sock) {
                my $n = $ws->pump;
                last if $n < 0;        # remote closed
                while (my $msg = $ws->try_recv) {
                    print $escape_nl->($msg->{payload}), "\n";
                }
            }
            elsif ($fh == \*STDIN) {
                my $line = <STDIN>;
                if (!defined $line) {
                    $sel->remove(\*STDIN);
                    $stdin_open = 0;
                    next;
                }
                chomp $line;
                next if $line eq '';
                $ws->send_text($line);
            }
        }
    }

    $ws->close(1000, 'bye') unless $ws->closed;
}

1;
