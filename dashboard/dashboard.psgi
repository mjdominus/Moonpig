#!perl
use strict;
use warnings;

use lib 'lib';

use File::Spec;
use HTML::Mason::Interp;
use Path::Class;
use Plack::App::Proxy;
use Plack::Builder;
use Plack::Request;
use Router::Dumb;
use Router::Dumb::Helper::FileMapper;
use Router::Dumb::Helper::RouteFile;
use Try::Tiny;

use namespace::autoclean;

package HTML::Mason::Commands {
  use Data::Dumper::HTML qw(dumper_html);
  use Data::GUID qw(guid_string);

  sub mc { sprintf '$%.02f', ((shift) / 100_000) }
}

my $router = Router::Dumb->new;

# GET targets
Router::Dumb::Helper::FileMapper->new({
  root          => 'dashboard/mason/public',
  target_munger => sub {
    my ($self, $filename) = @_;
    dir('public')->file( file($filename)->relative($self->root) )->stringify;
  },
})->add_routes_to($router);

# POST targets
Router::Dumb::Helper::FileMapper->new({
  root          => 'dashboard/mason/post',
  parts_munger  => sub { unshift @{ $_[1] }, 'post'; $_[1] },
  target_munger => sub {
    my ($self, $filename) = @_;
    dir('post')->file( file($filename)->relative($self->root) )->stringify;
  },
})->add_routes_to($router);

Router::Dumb::Helper::RouteFile->new({ filename => 'dashboard/routes' })
                               ->add_routes_to($router);

warn "ROUTING TABLE: \n";
for my $route ($router->ordered_routes) {
  warn sprintf "/%-50s -> %s\n", $route->path, $route->target;
}

my $interp = HTML::Mason::Interp->new(
  comp_root     => File::Spec->rel2abs("dashboard/mason"),
  request_class => 'Moonpig::Dashboard::Request',
  allow_globals => [ '$r' ],
);

my $app = sub {
  my ($env) = @_;
  my $req = Plack::Request->new($env);

  my $match = $router->route( $req->path_info );

  return [ 404 => [ 'Content-Type' => 'text/plain' ], [ 'not found' ] ]
    unless $match;

  my $comp = $interp->load( '/' . $match->target );

  try {
    my $output = '';

    $interp->set_global('$r', $req);

    $interp->make_request(
      comp => $comp,
      args => [
        %{ $req->body_parameters },
        $match->matches,
      ],
      out_method => \$output,
    )->exec;

    return [
      200 => [ 'Content-Type' => 'text/html' ], [ $output ]
    ];
  } catch {
    if (try { $_->isa('Moonpig::Dashboard::Redirect') }) {
      my $uri  = URI->new_abs( $_->uri, $req->uri );
      return [ 302, [ Location => $uri ], [] ];
    }
    die $_;
  };
};

builder {
  # enable 'Debug';
  enable(
    "Plack::Middleware::Static",
    path => qr{^/(images|js|css)/},
    root => 'dashboard/static/'
  );

  mount "/moonpig" => Plack::App::Proxy->new(
    remote => $ENV{MOONPIG_URI},
  )->to_app;

  mount "/" => $app;
};