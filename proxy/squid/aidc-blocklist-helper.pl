#!/usr/bin/perl
# aidc-blocklist-helper: answers squid's "is this destination on the malware
# blocklist?" (NET-16), through squid's external_acl_type hook.
#
# Why a helper at all: squid used to load the list itself (acl dstdomain "<file>").
# A new list then needed a squid reload, and a squid reload is a restart: with
# ~2.7M entries it refused every connection for ~20 s, at startup and on every
# refresh (issue #34). Squid never reloads for the list now; this helper reads the
# file on disk and starts using a new one as soon as the refresher swaps it in.
#
# How: the list is sorted in byte order (the refresher sorts with LC_ALL=C), so
# Search::Dict (core Perl) finds a domain by binary search on the file: ~4 MB of
# memory rather than a copy of the list, and ~0.2 ms for a new domain, which squid
# then caches (ttl on the external_acl_type line).
#
# A listed domain blocks its subdomains: the feeds list domains to block, and the
# taint classifier in the policy sidecar already walks parent domains the same way.
#
# Protocol (concurrency > 0): squid writes "<channel-id> <host> -", one per line
# (the trailing "-" is squid's placeholder for acl values; whitespace-split and take
# the first two fields, never "the rest of the line"); the
# answer is "<channel-id> OK" (listed: the acl matches, and the request is denied),
# "<channel-id> ERR" (not listed), or "<channel-id> BH" (no list to read). BH fails
# closed on purpose: a sandbox proxy that cannot check the list must not wave
# everything through.

use strict;
use warnings;
use Search::Dict;

$| = 1;

my $list = $ARGV[0] // '/etc/squid/blocklist.txt';
my ($fh, $dev, $ino);

# Open the list, or the new one if the refresher has swapped it (an atomic rename
# gives it a new inode). The open handle keeps the old file readable until then, so a
# failed re-open leaves the last good list in service.
sub current_list {
    my @st = stat $list;
    if (@st && !(defined $ino && $st[0] == $dev && $st[1] == $ino)) {
        if (open my $new, '<', $list) {
            ($fh, $dev, $ino) = ($new, $st[0], $st[1]);
        }
    }
    return $fh;
}

sub listed {
    my ($f, $domain) = @_;
    look $f, $domain;
    my $line = <$f>;
    return defined $line && $line eq "$domain\n";
}

# The host, then each parent domain: a.b.example.com, b.example.com, example.com, com.
sub blocked {
    my ($f, $host) = @_;
    $host = lc $host;
    $host =~ s/\.$//;
    # An address has no parent domains: look it up as written.
    return listed($f, $host) ? 1 : 0 if $host =~ /^[0-9.]+$/ || $host =~ /:/;
    my @labels = split /\./, $host;
    for my $i (0 .. $#labels) {
        return 1 if listed($f, join '.', @labels[$i .. $#labels]);
    }
    return 0;
}

while (my $request = <STDIN>) {
    chomp $request;
    my ($channel, $host) = split ' ', $request;
    next unless defined $channel;
    my $f = current_list();
    if (!$f) {
        print "$channel BH message=\"aidc: no blocklist at $list\"\n";
    } elsif (defined $host && length $host && blocked($f, $host)) {
        print "$channel OK\n";
    } else {
        print "$channel ERR\n";
    }
}
