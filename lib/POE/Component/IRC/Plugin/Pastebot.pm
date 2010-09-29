package POE::Component::IRC::Plugin::Pastebot;

use strict;
use warnings FATAL => 'all';
use Carp;
use POE;
use POE::Component::IRC::Plugin qw(:ALL);
use POE::Component::IRC::Common qw(l_irc parse_user);
use POE::Component::Server::Pastebot;

sub new {
    my ($package) = shift;
    croak "$package requires an even number of arguments" if @_ & 1;
    my $self = bless { @_ }, $package;

    local $@ = undef;
    if (!eval { $self->{Pastebot}->isa('POE::Component::Server::Pastebot') }) {
        $self->{own_pastebot} = 1;
    }

    if (defined $self->{Where} && ref $self->{Where} ne 'HASH') {
        croak "'Where' must be a hash";
    }

    while (my ($network, $channels) = each %{ $self->{Where} }) {
        if (ref $channels ne 'ARRAY'
            && !(ref $channels eq 'SCALAR' && $channels eq 'all')) {
            croak "Value '$network' in 'Where' must be 'all' or an arrayref";
        }
    }


    return $self;
}

sub PCI_register {
    my ($self, $irc, %args) = @_;

    $self->{networks}{$irc} = $args{network};
    $self->{ircs}{ $args{network} } = $irc;
    $self->{status}         = $args{status};

    if (!$irc->isa('POE::Component::IRC::State')) {
        die  __PACKAGE__ . ' requires PoCo::IRC::State or a subclass thereof';
    }

    $irc->plugin_register($self, 'SERVER', qw(
        disconnected
        join
        part
        kick
    ));

    if (!defined $self->{session_id}) {
        POE::Session->create(
            object_states => [
                $self => [qw(_start _stop pastebot_pasted)],
            ],
        );
    }

    if ($irc->logged_in()) {
        my @current = $irc->channel_list();

        my $network = $self->{networks}{$irc};
        for my $chan (@current) {
            my $lchan = l_irc($chan, $irc->isupport('MAPPING'));
            if ($self->_will_paste_to($irc, $chan)) {
                $self->{Pastebot}->add_place("$network/$lchan");
            }
        }
    }

    $self->{registered}++;
    return 1;
}

sub PCI_unregister {
    my ($self, $irc) = @_;

    $self->{registered}--;
    if (!$self->{registered}) {
        if ($self->{own_pastebot}) {
            $self->{Pastebot}->shutdown();
        }
        else {
            $self->{Pastebot}->unregister($self->{session_id});
        }
        delete $self->{Pastebot};
    }
    return 1;
}

sub _start {
    my ($self, $session) = @_[OBJECT, SESSION];
    my $irc = $self->{irc};
    $self->{session_id} = $session->ID();

    if ($self->{own_pastebot} && !$self->{Pastebot}) {
        $self->{Pastebot} = POE::Component::Server::Pastebot->new(
            (ref $self->{Pastebot_args} eq 'HASH'
                ? %{ $self->{Pastebot_args} }
                : ()
            )
        );
    }

    $self->{Pastebot}->register($self->{session_id});
    return;
}

sub _stop {
    my ($self) = $_[OBJECT];
    delete $self->{session_id};
    return;
}

sub _will_paste_to {
    my ($self, $irc, $chan) = @_;
    my $lchan = l_irc($chan, $irc->isupport('MAPPING'));
    my $network = $self->{networks}{$irc};

    my $channels = $self->{Where}{$network};
    if (!keys %{ $self->{Where} }
        || ref $channels eq 'SCALAR' && $channels eq 'all'
        || grep { l_irc($_, $irc->isupport('MAPPING')) eq $lchan } @$channels) {
        return 1;
    }

    return;
}

sub S_disconnected {
    my ($self, $irc) = splice @_, 0, 2;
    my @channels = keys %{ ${ $_[2] } };
    my $network = $self->{networks}{$irc};

    for my $chan (@channels) {
        my $lchan = l_irc($chan, $irc->isupport('MAPPING'));
        if ($self->_will_paste_to($irc, $chan)) {
            $self->{Pastebot}->remove_place("$network/$lchan");
        }
    }
    return PCI_EAT_NONE;
}

sub S_join {
    my ($self, $irc) = splice @_, 0, 2;
    my $joiner = parse_user(${ $_[0] });
    my $chan   = ${ $_[1] };
    my $lchan  = l_irc($chan, $irc->isupport('MAPPING'));
    return PCI_EAT_NONE if $joiner ne $irc->nick_name();

    if ($self->_will_paste_to($irc, $chan)) {
        my $network = $self->{networks}{$irc};
        $self->{Pastebot}->add_place("$network/$chan");
    }
    return PCI_EAT_NONE;
}

sub S_kick {
    my ($self, $irc) = splice @_, 0, 2;
    my $chan   = ${ $_[1] };
    my $victim = ${ $_[2] };
    my $lchan  = l_irc($chan, $irc->isupport('MAPPING'));
    return PCI_EAT_NONE if $victim ne $irc->nick_name();

    if ($self->_will_paste_to($irc, $chan)) {
        my $network = $self->{networks}{$irc};
        $self->{Pastebot}->remove_place("$network/$lchan");
    }
    return PCI_EAT_NONE;
}

sub S_part {
    my ($self, $irc) = splice @_, 0, 2;
    my $parter = parse_user(${ $_[0] });
    my $chan   = ${ $_[1] };
    my $lchan  = l_irc($chan, $irc->isupport('MAPPING'));
    return PCI_EAT_NONE if $parter ne $irc->nick_name();

    if ($self->_will_paste_to($irc, $chan)) {
        my $network = $self->{networks}{$irc};
        $self->{Pastebot}->remove_place("$network/$lchan");
    }
    return PCI_EAT_NONE;
}

sub pastebot_pasted {
    my ($self, $place, $nick, $address, $summary, $lines, $link)
        = @_[OBJECT, ARG0..$#_];

    return if !defined $place || !length $place;
    my ($network, $chan) = split /\//, $place, 2;
    my $irc = $self->{ircs}{$network};
    return if !$self->_will_paste_to($irc, $chan);
    return if !$irc->is_channel_member($chan, $nick);

    # let's use the canonical capitalization
    my $nickinfo = $irc->nick_info($nick);
    $nick = $nickinfo->{Nick};

    my $s = $lines == 1 ? '' : 's';
    my $message = "$nick at $address pasted \"$summary\" ($lines line$s) at $link";
    $irc->yield(privmsg => $chan, $message);
    return;
}

1;

=encoding utf8

=head1 NAME

POE::Component::IRC::Plugin::Pastebot - A Pastebot with IRC announcements

=head1 SYNOPSIS

To quickly get an IRC bot with this plugin up and running, you can use
L<App::Pocoirc|App::Pocoirc>:

 $ pocoirc -s irc.perl.org -j '#bots' -a 'Pastebot{ "pastebot_args":{ "paste_dir":"/tmp/pastes", "iname":"http://foo.com:8888" } }'

Or use it in your code:

 use POE::Component::IRC::Plugin::Pastebot

 my $pastebot = POE::Component::IRC::Plugin::Pastebot->new(
     Where => {
         freenode => ['#mychannel', '#myotherchannel'],
     },
     Pastebot_args => {
          # ...
     },
 );

 $irc->plugin_add(
     Pastebot => $pastebot,
     network  => 'freenode',
 ));

=head1 DESCRIPTION

This plugin requires the IRC component to be
L<POE::Component::IRC::State|POE::Component::IRC::State> or a subclass thereof.

B<Note>: This plugin can be loaded into multiple IRC components simultaneously.
It expects a C<< network => 'foo' >> parameter when being registered
(C<< $irc->plugin_add('Alias', Plugin->(), network => 'foo' >>).

=head1 METHODS

=head2 C<new>

Takes the following optional arguments:

B<'Where'>, a hash reference telling the plugin in which channels it should
be active. The keys are network names, the values are either C<'all'> or an
array reference of channel names. If you don't supply this argument, the
plugin will be active in all channels on all networks.

C<'Pastebot_args'>, a hash reference of arguments which will be passed to
L<POE::Component::Server::Pastebot|POE::Component::Server::Pastebot>'s
constructor.

B<'Pastebot'>, an already existing pastebot object to use, if you don't want
the plugin to create one for you.

Returns a plugin object suitable for feeding to
L<POE::Component::IRC|POE::Component::IRC>'s C<plugin_add> method.

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=head1 LICENSE AND COPYRIGHT

Copyright 2010 Hinrik E<Ouml>rn SigurE<eth>sson

This program is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
