package Moonpig::Role::Collection::CreditExtras;
use Class::MOP;
use Moose::Role;
use MooseX::Types::Moose qw(Int Str);
use Moonpig::Types qw(PositiveMillicents);
use Moonpig::Util qw(cents class);
use Stick::Publisher 0.20110324;
use Stick::Publisher::Publish 0.20110504;

publish accept_payment => { -http_method => 'post',
                            -path => 'accept_payment',
                            amount => PositiveMillicents,
                            type => Str,
                          } => sub {
  my ($self, $arg) = @_;
  my $type = $arg->{type};

  return Moonpig->env->storage->do_rw(sub {
    my $credit = $self->owner->add_credit(
      class("Credit::$type"),
      { amount => $arg->{amount} });
    $self->owner->process_credits;
    return $credit;
  });
};

1;

