package Mojolicious::Plugin::Swagger2;

=head1 NAME

Mojolicious::Plugin::Swagger2 - Mojolicious plugin for Swagger2

=head1 DESCRIPTION

L<Mojolicious::Plugin::Swagger2> is L<Mojolicious::Plugin> that add routes and
input/output validation to your L<Mojolicious> application.

Please read L<http://thorsen.pm/perl/programming/2015/07/05/mojolicious-swagger2.html>
for an introduction to this plugin and reasons for why you would to use it.

Have a look at this L<example blog app|https://github.com/jhthorsen/swagger2/tree/master/t/blog>
too see a complete working example, with a database backend. Questions and
comments on how to improve the example are very much welcome.

=over 4

=item * L<Swagger spec|https://github.com/jhthorsen/swagger2/blob/master/t/blog/api.json>

=item * L<Application|https://github.com/jhthorsen/swagger2/blob/master/t/blog/lib/Blog.pm>

=item * L<Controller|https://github.com/jhthorsen/swagger2/blob/master/t/blog/lib/Blog/Controller/Posts.pm>

=item * L<Tests|https://github.com/jhthorsen/swagger2/blob/master/t/authenticate.t>

=back

=head1 SYNOPSIS

=head2 Swagger specification

The input L</url> to given as argument to the plugin need to point to a
valid L<swagger|https://github.com/swagger-api/swagger-spec/blob/master/versions/2.0.md>
document.

Every operation must have a "x-mojo-controller" specified, so this plugin
knows where to look for the decamelized "operationId", which is used as
method name. C<x-mojo-controller> can be defined on different levels
and gets inherited unless defined more specific:

  ---
  swagger: 2.0
  basePath: /api
  x-mojo-controller: MyApp::Controller::Default
  paths:
    /pets:
      x-mojo-controller: MyApp::Controller::ForEveryHttpMethodUnderPets
      get:
        x-mojo-controller: MyApp::Controller::Petstore
        x-mojo-around-action: MyApp::authenticate_api_request
        operationId: listPets
        parameters: [ ... ]
        responses:
          200: { ... }

=head2 Application

The application need to load the L<Mojolicious::Plugin::Swagger2> plugin,
with a URL to the API specification. The plugin will then add all the routes
defined in the L</Swagger specification>.

  use Mojolicious::Lite;
  plugin Swagger2 => { url => app->home->rel_file("api.yaml") };
  app->start;

=head2 Controller

The method names defined in the controller will be a
L<decamelized|Mojo::Util::decamelize> version of C<operationId>.

The example L</Swagger specification> above, will result in
C<list_pets()> in the controller below to be called. This method
will receive the current L<Mojolicious::Controller> object, input arguments
and a callback. The callback should be called with a HTTP status code, and
a data structure which will be validated and serialized back to the user
agent.

  package MyApp::Controller::Petstore;

  sub list_pets {
    my ($c, $input, $cb) = @_;
    $c->$cb({limit => 123}, 200);
  }

=head2 Protected API

It is possible to protect your API, using a custom route:

  use Mojolicious::Lite;

  my $route = app->routes->under->to(
    cb => sub {
      my $c = shift;
      return 1 if $c->param('secret');
      return $c->render(json => {error => "Not authenticated"}, status => 401);
    }
  );

  plugin Swagger2 => {
    route => $route,
    url   => app->home->rel_file("api.yaml")
  };

=head2 Custom placeholders

The default placeholder type is the
L<generic placeholder|https://metacpan.org/pod/distribution/Mojolicious/lib/Mojolicious/Guides/Routing.pod#Generic-placeholders>,
meaning ":". This can be customized using C<x-mojo-placeholder> in the
API specification. The example below will enforce a
L<relaxed placeholder|https://metacpan.org/pod/distribution/Mojolicious/lib/Mojolicious/Guides/Routing.pod#Relaxed-placeholders>:

  ---
  swagger: 2.0
  basePath: /api
  paths:
    /pets:
      get:
        x-mojo-controller: MyApp::Controller::Petstore
        operationId: listPets
        parameters:
        - name: ip
          in: path
          type: string
          x-mojo-placeholder: "#"
        responses:
          200: { ... }

=head2 Around action hook

The C<x-mojo-around-action> value is optional, but can hold the name of a
method to call, which wraps around the autogenerated action which does input
and output validation. This means that any data sent to the server is not
yet converted into C<$input> to your action.

Here is an example method which match the C<x-mojo-around-action> from
L</Swagger specification>, C<MyApp::authenticate_api_request>:

  package MyApp;

  sub authenticate_api_request {
    my ($next, $c, $action_spec) = @_;

    # Go to the action if the Authorization header is valid
    return $next->($c) if $c->req->headers->authorization eq "s3cret!";

    # ...or render an error if not
    return $c->render_swagger(
      {errors => [{message => "Invalid authorization key", path => "/"}]},
      {},
      401
    );
  }

C<x-mojo-around-action> is also inherited from most levels, meaning that you
define it globally for your whole API if you like:

  ---
  x-mojo-around-action: MyApp::protect_any_resource
  paths:
    /pets:
      x-mojo-around-action: MyApp::protect_any_method_under_foo
      get:
        x-mojo-around-action: MyApp::protect_just_this_resource

This feature is EXPERIMENTAL and can change without notice.

=head2 Stash variables

=head3 swagger

The L<Swagger2> object used to generate the routes is available
as C<swagger> from L<stash|Mojolicious/stash>. Example code:

  sub documentation {
    my ($c, $args, $cb);
    $c->$cb($c->stash('swagger')->pod->to_string, 200);
  }

=cut

use Mojo::Base 'Mojolicious::Plugin';
use Mojo::JSON;
use Mojo::Util 'decamelize';
use Swagger2;
use Swagger2::SchemaValidator;
use constant DEBUG => $ENV{SWAGGER2_DEBUG} || 0;

=head1 ATTRIBUTES

=head2 url

Holds the URL to the swagger specification file.

=cut

has url => '';
has _validator => sub { Swagger2::SchemaValidator->new; };

=head1 HELPERS

=head2 render_swagger

  $c->render_swagger(\%err, \%data, $status);

This method is used to render C<%data> from the controller method. The C<%err>
hash will be empty on success, but can contain input/output validation errors.
C<$status> is the HTTP status code to use:

=over 4

=item * 200

The default C<$status> is 200, unless the method handling the request sent back
another value. C<%err> will be empty in this case.

=item * 400

This module will set C<$status> to 400 on invalid input. C<%err> then contains
a data structure describing the errors. The default is to render a JSON
document, like this:

  {
    "valid": false,
    "errors": [
      {
        "message": "string value found, but a integer is required",
        "path": "/limit"
      },
      ...
    ]
  }

=item * 500

This module will set C<$status> to 500 on invalid response from the handler.
C<%err> then contains a data structure describing the errors. The default is
to render a JSON document, like this:

  {
    "valid": false,
    "errors": [
      {
        "message": "is missing and it is required",
        "path": "/limit"
      },
      ...
    ]
  }

=item * 501

This module will set C<$status> to 501 if the given controller has not
implemented the required method. C<%err> then contains a data structure
describing the errors. The default is to render a JSON document, like this:

  {
    "valid": false,
    "errors": [
      {
        "message": "No handler defined.",
        "path": "/"
      }
    ]
  }

=back

=cut

sub render_swagger {
  my ($c, $err, $data, $status) = @_;

  return $c->render(json => $err, status => $status) if %$err;
  return $c->render(ref $data ? (json => $data) : (text => $data), status => $status);
}

=head1 METHODS

=head2 register

  $self->register($app, \%config);

This method is called when this plugin is registered in the L<Mojolicious>
application.

C<%config> can contain these parameters:

=over 4

=item * route

Need to hold a Mojolicious route object. See L</Protected API> for an example.

This parameter is optional.

=item * swagger

A C<Swagger2> object. This can be useful if you want to keep use the
specification to other things in your application. Example:

  use Swagger2;
  my $swagger = Swagger2->new->load($url);
  plugin Swagger2 => {swagger => $swagger2};
  app->defaults(swagger_spec => $swagger->api_spec);

Either this parameter or C<url> need to be present.

=item * url

This will be used to construct a new L<Swagger2> object. The C<url>
can be anything that L<Swagger2/load> can handle.

Either this parameter or C<swagger> need to be present.

=back

=cut

sub register {
  my ($self, $app, $config) = @_;
  my ($paths, $r, $swagger);

  $swagger = $config->{swagger} || Swagger2->new->load($config->{url} || '"url" is missing');
  $swagger = $swagger->expand;
  $paths   = $swagger->api_spec->get('/paths') || {};

  $self->url($swagger->url);
  $app->helper(render_swagger => \&render_swagger) unless $app->renderer->get_helper('render_swagger');

  $r = $config->{route};

  if ($r and !$r->pattern->unparsed) {
    $r->to(swagger => $swagger);
    $r = $r->any($swagger->base_url->path->to_string);
  }
  if (!$r) {
    $r = $app->routes->any($swagger->base_url->path->to_string);
    $r->to(swagger => $swagger);
  }

  for my $path (keys %$paths) {
    $paths->{$path}{'x-mojo-around-action'} ||= $swagger->api_spec->get('/x-mojo-around-action');
    $paths->{$path}{'x-mojo-controller'}    ||= $swagger->api_spec->get('/x-mojo-controller');

    for my $http_method (grep { !/^x-/ } keys %{$paths->{$path}}) {
      my $info       = $paths->{$path}{$http_method};
      my $route_path = $path;
      my %parameters = map { ($_->{name}, $_) } @{$info->{parameters} || []};

      $route_path =~ s/{([^}]+)}/{
        my $name = $1;
        my $type = $parameters{$name}{'x-mojo-placeholder'} || ':';
        "($type$name)";
      }/ge;

      warn "[Swagger2] Add route $http_method $route_path\n" if DEBUG;
      $info->{'x-mojo-around-action'} ||= $paths->{$path}{'x-mojo-around-action'};
      $info->{'x-mojo-controller'}    ||= $paths->{$path}{'x-mojo-controller'};
      $r->$http_method($route_path => $self->_generate_request_handler($route_path, $info));
    }
  }
}

sub _generate_request_handler {
  my ($self, $route_path, $config) = @_;
  my $op         = $config->{operationId} || $route_path;
  my $method     = decamelize(ucfirst $op);
  my $controller = $config->{'x-mojo-controller'} or _die($config, "x-mojo-controller is missing in the swagger spec");
  my $defaults   = {};
  my $handler;

  $handler = sub {
    my $c = shift;
    my ($method_ref, $v, $input);

    unless (eval "require $controller;1") {
      $c->app->log->error($@);
      return $c->render_swagger($self->_not_implemented('Controller not implemented.'), {}, 501);
    }
    unless ($method_ref = $controller->can($method)) {
      $method_ref = $controller->can(sprintf '%s_%s', $method, lc $c->req->method)
        and warn "HTTP method name is not used in method name lookup anymore!";
    }
    unless ($method_ref) {
      $c->app->log->error(
        qq(Can't locate object method "$method" via package "$controller. (Something is wrong in @{[$self->url]})"));
      return $c->render_swagger($self->_not_implemented(qq(Method "$op" not implemented.)), {}, 501);
    }

    bless $c, $controller;    # ugly hack?
    ($v, $input) = $self->_validate_input($c, $config);

    return $c->render_swagger($v, {}, 400) unless $v->{valid};
    return $c->delay(
      sub { $c->$method_ref($input, shift->begin); },
      sub {
        my $delay  = shift;
        my $data   = shift;
        my $status = shift || 200;
        my $format = $config->{responses}{$status} || $config->{responses}{default} || undef;
        my @err
          = !$format ? $self->_validator->validate($data, {})
          : $format->{schema} ? $self->_validator->validate($data, $format->{schema})
          :                     ();

        return $c->render_swagger({errors => \@err, valid => Mojo::JSON->false}, $data, 500) if @err;
        return $c->render_swagger({}, $data, $status);
      },
    );
  };

  for my $p (@{$config->{parameters} || []}) {
    $defaults->{$p->{name}} = $p->{default} if $p->{in} eq 'path' and defined $p->{default};
  }

  if (my $around_action = $config->{'x-mojo-around-action'}) {
    my $next = $handler;
    $handler = sub {
      my $c = shift;
      my $around = $c->can($around_action) || $around_action;
      $around->($next, $c, $config);
    };
  }

  return $defaults, $handler;
}

sub _not_implemented {
  my ($self, $message) = @_;
  return {valid => Mojo::JSON->false, errors => [{message => $message, path => '/'}]};
}

sub _validate_input {
  my ($self, $c, $config) = @_;
  my $body    = $c->req->body_params;
  my $headers = $c->req->headers;
  my $query   = $c->req->url->query;
  my (%input, %v);

  for my $p (@{$config->{parameters} || []}) {
    my ($in, $name) = @$p{qw( in name )};
    my ($value, @e);

    $value
      = $in eq 'query'    ? $query->param($name)
      : $in eq 'path'     ? $c->stash($name)
      : $in eq 'header'   ? $headers->header($name)
      : $in eq 'body'     ? $c->req->json
      : $in eq 'formData' ? $body->param($name)
      :                     "Invalid 'in' for parameter $name in schema definition";

    $value //= $p->{default};

    if (defined $value or Swagger2::_is_true($p->{required})) {
      my $type = $p->{type} || 'object';
      $value += 0 if $type =~ /^(?:integer|number)/ and $value =~ /^-?\d/;
      $value = ($value eq 'false' or !$value) ? Mojo::JSON->false : Mojo::JSON->true if $type eq 'boolean';

      # ugly hack
      if (ref $p->{items} eq 'HASH' and $p->{items}{collectionFormat}) {
        $value = _coerce_by_collection_format($p->{items}, $value);
      }

      if ($in eq 'body') {
        warn "[Swagger2] Validate $in @{[$c->req->body]}\n" if DEBUG;
        push @e,
          map { $_->{path} = $_->{path} eq "/" ? "/$name" : "/$name$_->{path}"; $_; }
          $self->_validator->validate($value, $p->{schema});
      }
      elsif (defined $value) {
        warn "[Swagger2] Validate $in $name=$value\n" if DEBUG;
        push @e, $self->_validator->validate({$name => $value}, {properties => {$name => $p}});
      }
      else {
        warn "[Swagger2] Validate $in $name=undef()\n" if DEBUG;
        push @e, $self->_validator->validate({}, {properties => {$name => $p}});
      }
    }

    $input{$name} = $value unless @e;
    push @{$v{errors}}, @e;
  }

  $v{valid} = @{$v{errors} || []} ? Mojo::JSON->false : Mojo::JSON->true;
  return \%v, \%input;
}

# copy/paste from JSON::Validator
sub _coerce_by_collection_format {
  my ($schema, $data) = @_;
  my $format = $schema->{collectionFormat};
  my @data = $format eq 'ssv' ? split / /, $data : $format eq 'tsv' ? split /\t/,
    $data : $format eq 'pipes' ? split /\|/, $data : split /,/, $data;

  return [map { $_ + 0 } @data] if $schema->{type} and $schema->{type} =~ m!^(integer|number)$!;
  return \@data;
}

sub _die {
  die "$_[1]: ", Mojo::Util::dumper($_[0]);
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014-2015, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
