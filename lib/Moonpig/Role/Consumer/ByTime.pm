package Moonpig::Role::Consumer::ByTime;
# ABSTRACT: a consumer that charges steadily as time passes

use Carp qw(confess croak);
use List::AllUtils qw(natatime);
use Moonpig;
use Moonpig::DateTime;
use Moonpig::Util qw(class days event sum sumof pair_rights);
use Moose::Role;
use MooseX::Types::Moose qw(ArrayRef Num);

use Moonpig::Logger '$Logger';
use Moonpig::Trait::Copy;

require Stick::Publisher;
Stick::Publisher->VERSION(0.20110324);
use Stick::Publisher::Publish 0.20110324;

with(
  'Moonpig::Role::Consumer::ChargesPeriodically',
  'Moonpig::Role::Consumer::InvoiceOnCreation',
  'Moonpig::Role::Consumer::MakesReplacement',
  'Moonpig::Role::Consumer::PredictsExpiration',
  'Moonpig::Role::StubBuild',
);

requires 'charge_pairs_on';

use Moonpig::Types qw(PositiveMillicents Time TimeInterval);

use namespace::autoclean;

sub now { Moonpig->env->now() }

sub charge_amount_on {
  my ($self, $date) = @_;

  my %charge_pairs = $self->charge_pairs($date);
  my $amount = sum(values %charge_pairs);

  return $amount;
}

sub initial_invoice_charge_pairs {
  my ($self) = @_;
  my @pairs = $self->charge_pairs_on( Moonpig->env->now );

  my $ratio = $self->proration_period / $self->cost_period;
  $pairs[$_] *= $ratio for grep { $_ % 2 } keys @pairs;

  return @pairs;
}

has cost_period => (
  is => 'ro',
  required => 1,
  isa => TimeInterval,
  traits => [ qw(Copy) ],
);

has proration_period => (
  is   => 'ro',
  isa  => TimeInterval,
  lazy => 1,
  default => sub { $_[0]->cost_period },
  # Note *not* copied explicitly; see copy_attr_hash__ decorator below
);

# Fix up the proration period in the copied consumer
around copy_attr_hash__ => sub {
  my ($orig, $self, @args) = @_;
  my $hash = $self->$orig(@args);
  $hash->{proration_period} = $self->_new_proration_period();
  return $hash;
};

sub _new_proration_period {
  my ($self) = @_;
  return $self->is_active
    ? $self->_estimated_remaining_funded_lifetime({ amount => $self->unapplied_amount, # XXX ???
                                                    ignore_partial_charge_periods => 0,
                                                  })
    : $self->proration_period;
}

after BUILD => sub {
  my ($self) = @_;
  Moonpig::X->throw({ ident => 'proration longer than cost period',
                      payload => {
                        proration_period => $self->proration_period,
                        cost_period => $self->cost_period,
                       }})
    if $self->proration_period > $self->cost_period;
};

after become_active => sub {
  my ($self) = @_;

  $self->grace_until( Moonpig->env->now  +  $self->grace_period_duration );

  $Logger->log([
    '%s: %s became active; grace until %s, next charge date %s',
    q{} . Moonpig->env->now,
    $self->ident,
    q{} . $self->grace_until,
    q{} . $self->next_charge_date,
  ]);
};

sub expiration_date;
publish expiration_date => { } => sub {
  my ($self) = @_;

  $self->is_active ||
    confess "Can't calculate remaining life for inactive consumer";

  my $remaining = $self->unapplied_amount;

  if ($remaining <= 0) {
    return $self->grace_until if $self->in_grace_period;
    return Moonpig->env->now;
  } else {
    return $self->next_charge_date +
      $self->_estimated_remaining_funded_lifetime({ amount => $remaining,
                                                   ignore_partial_charge_periods => 1,
                                                 });
  }
};

# returns amount of life remaining, in seconds
sub remaining_life {
  my ($self, $when) = @_;
  $when ||= $self->now();
  $self->expiration_date - $when;
}

sub will_die_soon { 0 } # Provided by MakesReplacement

sub estimated_lifetime {
  my ($self) = @_;

  if ($self->is_active) {
    return $self->expiration_date - $self->activated_at;
  } else {
    return $self->proration_period;
  }
}

################################################################
#
#

has grace_until => (
  is  => 'rw',
  isa => Time,
  clearer   => 'clear_grace_until',
  predicate => 'has_grace_until',
  traits => [ qw(Copy) ],
);

has grace_period_duration => (
  is  => 'rw',
  isa => TimeInterval,
  default => days(3),
  traits => [ qw(Copy) ],
);

sub in_grace_period {
  my ($self) = @_;

  return unless $self->has_grace_until;

  return $self->grace_until >= Moonpig->env->now;
}

################################################################
#
#

around charge => sub {
  my $orig = shift;
  my ($self, @args) = @_;

  return if $self->in_grace_period;

  $self->$orig(@args);
};

around charge_one_day => sub {
  my $orig = shift;
  my ($self, @args) = @_;

  if ($self->was_ever_funded and $self->does('Moonpig::Role::Consumer::MakesReplacement')) {
    $self->maybe_make_replacement;
  }

  unless ($self->can_make_payment_on( $self->next_charge_date )) {
    $self->expire;
    return;
  }

  $self->$orig(@args);
};

# how much do we charge each time we issue a new charge?
sub calculate_charge_pairs_on {
  my ($self, $date) = @_;

  my $n_periods = $self->cost_period / $self->charge_frequency;

  my @charge_pairs = $self->charge_pairs_on( $date );

  $charge_pairs[$_] /= $n_periods for grep { $_ % 2 } keys @charge_pairs;

  return @charge_pairs;
}

sub calculate_total_charge_amount_on {
  my ($self, $date) = @_;
  my @charge_pairs = $self->calculate_charge_pairs_on( $date );
  my $total_charge_amount = sum pair_rights @charge_pairs;

  return $total_charge_amount;
}

sub minimum_spare_change_amount {
  my ($self) = @_;
  return $self->calculate_total_charge_amount_on( Moonpig->env->now );
}

publish estimate_cost_for_interval => { interval => TimeInterval } => sub {
  my ($self, $arg) = @_;
  my $interval = $arg->{interval};
  my @pairs = $self->charge_pairs_on( Moonpig->env->now );
  my $total = sum pair_rights @pairs;
  return $total * ($interval / $self->cost_period);
};

sub can_make_payment_on {
  my ($self, $date) = @_;
  return
    $self->unapplied_amount >= $self->calculate_total_charge_amount_on($date);
}

sub _predicted_shortfall {
  my ($self) = @_;

  # First, figure out how much money we have and are due, and assume we're
  # going to get it all. -- rjbs, 2012-03-15
  my $guid = $self->guid;
  my @charges = grep { ! $_->is_abandoned && $guid eq $_->owner_guid }
                map  { $_->all_charges }
                $self->ledger->payable_invoices;
  my $funds = $self->unapplied_amount + (sumof { $_->amount } @charges);

  # Next, figure out how long that money will last us.
  my $estimated_remaining_funded_lifetime =
      $self->_estimated_remaining_funded_lifetime({ amount => $funds,
                                                   ignore_partial_charge_periods => 0,
                                                 });

  # Next, figure out long we think it *should* last us.
  my $want_to_live;
  if ($self->is_active) {
    $want_to_live = $self->proration_period
                  - ($self->next_charge_date - $self->activated_at);
  } else {
    $want_to_live = $self->proration_period;
  }

  return 0 if $estimated_remaining_funded_lifetime >= $want_to_live;

  # If you're going to run out of funds your final charge period, we don't
  # care.  In general, we plan to have charge_frequency stick with its default
  # value always: days(1).  If you were to use a days(30) charge frequency,
  # this could mean that someone could easily miss 29 days of service, which is
  # potentially more obnoxious than losing 23 hours. -- rjbs, 2012-03-16
  my $shortfall = $want_to_live - $estimated_remaining_funded_lifetime;
  return 0 if $shortfall < $self->charge_frequency;

  return $shortfall;
}

# Given an amount of money, estimate how long the money will last
# at current rates of consumption.
#
# If the money will last for a fractional number of charge periods, you
# might or might not want to count the final partial period.
#
sub _estimated_remaining_funded_lifetime {
  my ($self, $args) = @_;

  confess "Missing amount argument to _estimated_remaining_funded_lifetime"
    unless defined $args->{amount};

  my $each_charge = $self->calculate_total_charge_amount_on( Moonpig->env->now );

  Moonpig::X->throw("can't compute funded lifetime of negative-cost consumer")
    if $each_charge < 0;

  if ($each_charge == 0) {
    Moonpig::X->throw({
      ident => "can't compute funded lifetime of zero-cost consumer",
      payload => {
        consumer_guid => $self->guid,
        ledger_guid   => $self->ledger->guid,
      },
    });
  }

  my $periods     = $args->{amount} / $each_charge;
  $periods = int($periods) if $args->{ignore_partial_charge_periods};

  return $periods * $self->charge_frequency;
}

1;
