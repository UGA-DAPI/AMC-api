#! /usr/bin/perl -w
#
# Copyright (C) 2008-2014 Alexis Bienvenue <paamc@passoire.fr>
#
# This file is part of Auto-Multiple-Choice
#
# Auto-Multiple-Choice is free software: you can redistribute it
# and/or modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation, either version 2 of
# the License, or (at your option) any later version.
#
# Auto-Multiple-Choice is distributed in the hope that it will be
# useful, but WITHOUT ANY WARRANTY; without even the implied warranty
# of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Auto-Multiple-Choice.  If not, see
# <http://www.gnu.org/licenses/>.

package CommandeApi;

use Encode;

use AMC::Basic;


sub new {
    my %o    = (@_);
    my $self = {
        'commande' => '',
        'fin'      => '',
        'finw'     => '',
        'signal'   => 9,
        'o'        => {},
        'clear'    => 1,

        'messages'  => {},
        'variables' => {},

        'pid' => '',
        'fh'  => '',
    };

    for ( keys %o ) {
        $self->{$_} = $o{$_} if ( defined( $self->{$_} ) || /^niveau/ );
    }

    $self->{'commande'} = [ $self->{'commande'} ]
        if ( !ref( $self->{'commande'} ) );

    bless $self;

    return ($self);
}


sub proc_pid {
    my ($self)=(@_);
    return($self->{'pid'});
}

sub erreurs {
    my ($self)=(@_);
    return($self->{'messages'}->{'ERR'});
}

sub warnings {
    my ($self)=(@_);
    return($self->{'messages'}->{'WARN'});
}

sub variables {
    my ($self)=(@_);
    return(%{$self->{'variables'}});
}

sub variable {
    my ($self,$k)=(@_);
    return $self->{'variables'}->{$k};
}

sub quitte {
    my ($self)=(@_);

    $self->{closing}=1;

    my $pid=$self->proc_pid();

    kill $self->{'signal'},$pid if($pid =~ /^[0-9]+$/);

    $self->close(cancelled=>1);
}

sub execute {
    my ($self)=@_;

    $self->{'times'}=[times()];
    $self->{'pid'} = open($self->{'fh'},"-|",@{$self->{'commande'}});
    if(defined($self->{'pid'})) {

	$self->{'log'}->get_buffer()->set_text('') if($self->{'clear'});

    } else {
    print STDERR "ERROR execing command\n".join(' ',@{$self->{'commande'}})."\n";
    }
    my $fh=$self->{'fh'};
    while( my $line = decode("utf8",<$fh>) ) {
	  if($line =~ /^(ERR|INFO|WARN)/) {
	    chomp(my $lc=$line);
	    $lc =~ s/^(ERR|INFO|WARN)[:>]\s*//;
	    $self->{'message'}->{$1}=$lc;
	  }
	  if($line =~ /^VAR:\s*([^=]+)=(.*)/) {
	    $self->{'variables'}->{$1}=$2;
	  }
	  for my $k (qw/OK FAILED/) {
	    if($line =~ /^$k/) {
	      $self->{'variables'}->{$k}++;
	    }
	  }
    }
  &{$self->{'finw'}}($self,%data) if($self->{'finw'});
  &{$self->{'fin'}}($self,%data) if($self->{'fin'});
}





1;

