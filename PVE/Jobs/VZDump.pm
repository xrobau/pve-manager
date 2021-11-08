package PVE::Jobs::VZDump;

use strict;
use warnings;

use PVE::INotify;
use PVE::VZDump::Common;
use PVE::API2::VZDump;
use PVE::Cluster;

use base qw(PVE::Jobs::Plugin);

sub type {
    return 'vzdump';
}

my $props = PVE::VZDump::Common::json_config_properties();

sub properties {
    return $props;
}

sub options {
    my $options = {
	enabled => { optional => 1 },
	schedule => {},
    };
    foreach my $opt (keys %$props) {
	if ($props->{$opt}->{optional}) {
	    $options->{$opt} = { optional => 1 };
	} else {
	    $options->{$opt} = {};
	}
    }

    return $options;
}

sub run {
    my ($class, $conf) = @_;

    # remove all non vzdump related options
    foreach my $opt (keys %$conf) {
	delete $conf->{$opt} if !defined($props->{$opt});
    }

    $conf->{quiet} = 1; # do not write to stdout/stderr

    PVE::Cluster::cfs_update(); # refresh vmlist

    return PVE::API2::VZDump->vzdump($conf);
}

1;
