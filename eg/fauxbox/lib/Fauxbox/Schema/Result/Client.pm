package Fauxbox::Schema::Result::Client;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('clients');

__PACKAGE__->add_columns(id => {
  data_type         => 'INTEGER',
  is_auto_increment => 1,
});

__PACKAGE__->add_column('username');

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint([ qw(username) ]);

__PACKAGE__->has_many(
  accounts => 'Fauxbox::Schema::Result::Account',
  { 'foreign.client_id' => 'self.id' },
);

sub ledger_uri {
  my ($self, $extra) = @_;
  my $base = sprintf "/ledger/by-xid/%s", $self->xid;
  $base .= "/$extra" if defined $extra;
  return $base;
}

sub xid {
  my ($self) = @_;
  return sprintf "fauxbox:username:%s", $self->username;
}

1;
