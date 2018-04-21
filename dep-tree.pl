#!/usr/bin/env perl
use rjbs;

use DBI;
use Getopt::Long::Descriptive;
use Module::CoreList;
use Term::ANSIColor;

my ($opt, $usage) = describe_options(
  '%c %o DBFILE DIST [TARGET-DIST]',
  [ 'prune=s@',   'stop if you hit this path on the way to a target' ],
  [ 'output=s',   'how to print output; default: tree', { default => 'tree' } ],
  [ 'skip-core!', 'skip modules from the core' ],
  [ 'once',       'only print things the first time they appear' ],
);

my ($dbfile, $dist, $target) = @ARGV;

$usage->die unless $dbfile && $dist;

my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile", undef, undef);

my %seen;

my $sth = $dbh->prepare(
  "SELECT DISTINCT module_dist
  FROM dist_prereqs
  WHERE dist = ?
    AND type = 'requires'
    AND phase <> 'develop'
    AND module_dist IS NOT NULL
  ORDER BY LOWER(module_dist)",
);

sub dump_prereqs ($dist, $indent) {
  my @dists = _dists_required_by($dist);

  DIST: for (@dists) {
    if ($seen{$_}++) {
      next if $opt->once;
      print color('green');
      printf "%s%s\n", ('  ' x $indent), $_;
      print color('reset');
      # printf "%s%s\n", ('  ' x ($indent+1)), '<see above>';
    } else {
      print color('bold green');
      printf "%s%s\n", ('  ' x $indent), $_;
      print color('reset');
      dump_prereqs($_, $indent+1);
    }
  }
}

sub _dists_required_by ($dist) {
  my $rows = $dbh->selectall_arrayref(
    $sth,
    { Slice => {} },
    $dist,
  );

  return  grep { ! $opt->skip_core or ! defined $Module::CoreList::version{5.020000}{$_} }
          map  {; $_->{module_dist} } $rows->@*;
}

my %PATH_FOR;
sub _paths_between ($dist, $target, $path = []) {
  return $PATH_FOR{ $dist, $target } if exists $PATH_FOR{ $dist, $target };

  return $PATH_FOR{ $dist, $target } = $target if $dist eq $target;
  return $PATH_FOR{ $dist, $target } = undef if grep {; $_ eq $dist } @{ $opt->prune || [] };
  return $PATH_FOR{ $dist, $target } = undef unless my @prereqs = _dists_required_by($dist);

  my %in_path = map {; $_ => 1 } @$path;

  my %return;
  for my $prereq ( grep { ! $in_path{$_} } @prereqs ) {
    my $paths = _paths_between($prereq, $target, [ @$path, $prereq ]);
    $return{$prereq} = $paths if $paths;
  }

  return $PATH_FOR{ $dist, $target } = keys %return ? \%return : undef;
}

sub print_tree {

  my $print_tree = sub ($start, $struct, $depth = 0) {
    my $leader = '  ' x $depth;

    print "$leader$start\n";
    return unless ref $struct;

    for my $key (sort { fc $a cmp fc $b } keys %$struct) {
      my $value = $struct->{$key};
      __SUB__->($key, $struct->{$key}, $depth+1);
    }
  };

  $print_tree->(@_[0,1]);
}

sub print_dot ($start, $struct, $arg = {}) {
  print "digraph {\n";

  print qq{"$start" [style=filled,color=green];\n};
  print qq{"$arg->{target}" [style=filled,color=red];\n} if $arg->{target};

  my %seen;

  my $print_tree = sub ($start, $struct) {
    return unless ref $struct;
    for my $dist (keys %$struct) {
      print qq{"$start" -> "$dist";\n} unless $seen{$start, $dist}++;
      __SUB__->($dist, $struct->{$dist});
    }
  };

  $print_tree->(@_[0,1]);

  print "}\n";
}

if ($target) {
  if (my $tree = _paths_between($dist, $target)) {
    my $subname = "print_" . $opt->output;
    unless (main->can($subname)) {
      warn "unknown outputter " . $opt->output . " so using tree\n";
      $subname = "print_tree";
    }

    # LA LA LA I AM AT A HACKATHON SO I CODE FAST AND NOT GOOD LA LA LA
    main->can($subname)->($dist, $tree, { target => $target });
  } else {
    print "no path from $dist to $target\n";
  }
} else {
  dump_prereqs($dist, 0);
}
