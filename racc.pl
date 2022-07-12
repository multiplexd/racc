#!/usr/bin/perl

# Copyright (C) 2022 multi
# Licensed under the ISC licence.
# See the LICENSE file for more details.

use strict;
use warnings;
use v5.10;

use IRC::Utils qw/eq_irc lc_irc/;
use POE;
use POE::Component::IRC;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::BotAddressed;
use POE::Component::IRC::Plugin::NickReclaim;
use POE::Component::IRC::Plugin::NickServID;
use YAML qw/LoadFile/;

# autoflush streams.
$|++;

if ($#ARGV < 0) {
    die 'missing required argument';
}

# error handling? what's that?
my %config = %{ LoadFile($ARGV[0]) };

my $irc = POE::Component::IRC::State->spawn(
    Nick => $config{'nick'},
    Username => (exists $config{'username'}) ? $config{'username'} : $config{'nick'},
    Ircname => (exists $config{'ircname'}) ? $config{'ircname'} : $config{'nick'},
    Server => $config{'server'},
    Port => (exists $config{'port'}) ? $config{'port'} : 6667,
    UseSSL => $config{'usessl'},
    useipv6 => $config{'useipv6'},
    LocalAddr => $config{'localaddr'},
    Password => $config{'password'},
);

{
    # casefolding adjustments
    my %tgts;
    for my $k (keys %{$config{'targets'}}) {
        $tgts{lc_irc($k)} = ${$config{'targets'}}{$k};
    }
    $config{'targets'} = \%tgts;
}

$config{'irc'} = $irc;

$irc->plugin_add(
    'AutoJoin',
    POE::Component::IRC::Plugin::AutoJoin->new(
        Channels => $config{'channels'}, # this should be a hash reference. probably
        NickServ_delay => (exists $config{'autojoin_delay'}) ? $config{'autojoin_delay'} : 10,
    ),
);

$irc->plugin_add(
    'Connector',
    POE::Component::IRC::Plugin::Connector->new(),
);

$irc->plugin_add(
    'BotAddressed',
    POE::Component::IRC::Plugin::BotAddressed->new(
        eat => 1, # nom!
    ),
);

if (exists $config{'nick_reclaim'}) { # configurable, znc can also do this
    $irc->plugin_add(
        'NickReclaim',
        POE::Component::IRC::Plugin::NickReclaim->new(),
    );
}

if (exists $config{'nickserv_password'}) {
    $irc->plugin_add(
        'NickServID',
        POE::Component::IRC::Plugin::NickServID->new(
            Password => $config{'nickserv_password'},
        ),
    );
}

# register callback handlers
POE::Session->create(
    inline_states => {
        _start => \&on_startup,
        irc_connected => \&on_connected,
        irc_msg => \&on_private,
        irc_bot_addressed => \&on_addressed,
    },
    heap => \%config,
);

# start main application
POE::Kernel->run();

sub on_startup {
    my $irc = ${$_[HEAP]}{'irc'};

    # register event handlers, commence connection to irc server
    $irc->yield('register', 'all');
    $irc->yield('connect', {});
}

sub on_connected {
    my $h = $_[HEAP];
    my $irc = ${$h}{'irc'};

    if (exists ${$h}{'initial_modes'}) {
        $irc->yield('mode', $irc->nick_name(), ${$h}{'initial_modes'});
    }
}

sub on_private {
    my ($h, $mask, $msg) = @_[HEAP, ARG0, ARG2];
    handle_admin_message($h, $mask, $msg);
}

sub on_addressed {
    my ($h, $mask, $chans, $msg) = @_[HEAP, ARG0..ARG2];
    my $irc = ${$h}{'irc'};
    my %tgts = %{${$h}{'targets'}};

    return if handle_admin_message($h, $mask, $msg);

    for my $ch (@{$chans}) {
        if (grep { eq_irc($_, $ch) } (keys %tgts)) {
            my @t = @{$tgts{lc_irc($ch)}};
            my $msg = sprintf "(cc %s)", (join ' ', @t);

            $irc->yield('privmsg', $ch, $msg);
        }
    }
}

sub handle_admin_message {
    my ($h, $mask, $msg) = @_;
    my ($who) = split /!/, $mask;

    # type safety? what's that?
    if (exists ${$h}{'owners'} and grep { eq_irc($_, $who) } @{${$h}{'owners'}}) {
        if ($msg =~ /^\s*quit\s*$/) {
            ${$h}{'irc'}->yield('shutdown');
            return 1;
        }
    }

    return 0;
}
