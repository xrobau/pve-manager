package PVE::Ceph::Services;

use strict;
use warnings;

use PVE::Ceph::Tools;
use PVE::Tools qw(run_command);
use PVE::RADOS;

use File::Path;

sub ceph_service_cmd {
    my ($action, $service) = @_;

    my $pve_ceph_cfgpath = PVE::Ceph::Tools::get_config('pve_ceph_cfgpath');
    if (PVE::Ceph::Tools::systemd_managed()) {

	if ($service && $service =~ m/^(mon|osd|mds|mgr|radosgw)(\.([A-Za-z0-9\-]{1,32}))?$/) {
	    $service = defined($3) ? "ceph-$1\@$3" : "ceph-$1.target";
	} else {
	    $service = "ceph.target";
	}

	PVE::Tools::run_command(['/bin/systemctl', $action, $service]);

    } else {
	# ceph daemons does not call 'setsid', so we do that ourself
	# (fork_worker send KILL to whole process group)
	PVE::Tools::run_command(['setsid', 'service', 'ceph', '-c', $pve_ceph_cfgpath, $action, $service]);
    }
}

# MDS

sub list_local_mds_ids {
    my $mds_list = [];
    my $ceph_mds_data_dir = PVE::Ceph::Tools::get_config('ceph_mds_data_dir');
    my $ccname = PVE::Ceph::Tools::get_config('ccname');

    PVE::Tools::dir_glob_foreach($ceph_mds_data_dir, qr/$ccname-(\S+)/, sub {
	my (undef, $mds_id) = @_;
	push @$mds_list, $mds_id;
    });

    return $mds_list;
}

sub get_cluster_mds_state {
    my ($rados) = @_;

    my $mds_state = {};

    if (!defined($rados)) {
	$rados = PVE::RADOS->new();
    }

    my $add_state = sub {
	my ($mds) = @_;

	my $state = {};
	$state->{addr} = $mds->{addr};
	$state->{rank} = $mds->{rank};
	$state->{standby_replay} = $mds->{standby_replay} ? 1 : 0;
	$state->{state} = $mds->{state};

	$mds_state->{$mds->{name}} = $state;
    };

    my $mds_dump = $rados->mon_command({ prefix => 'mds stat' });
    my $fsmap = $mds_dump->{fsmap};


    foreach my $mds (@{$fsmap->{standbys}}) {
	$add_state->($mds);
    }

    my $fs_info = $fsmap->{filesystems}->[0];
    my $active_mds = $fs_info->{mdsmap}->{info};

    # normally there's only one active MDS, but we can have multiple active for
    # different ranks (e.g., different cephs path hierarchy). So just add all.
    foreach my $mds (values %$active_mds) {
	$add_state->($mds);
    }

    return $mds_state;
}

sub is_any_mds_active {
    my ($rados) = @_;

    if (!defined($rados)) {
	$rados = PVE::RADOS->new();
    }

    my $mds_dump = $rados->mon_command({ prefix => 'mds stat' });
    my $fs = $mds_dump->{fsmap}->{filesystems};

    if (!($fs && scalar(@$fs) > 0)) {
	return undef;
    }
    my $active_mds = $fs->[0]->{mdsmap}->{info};

    for my $mds (values %$active_mds) {
	return 1 if $mds->{state} eq 'up:active';
    }

    return 0;
}

sub create_mds {
    my ($id, $rados) = @_;

    # `ceph fs status` fails with numeric only ID.
    die "ID: $id, numeric only IDs are not supported\n"
	if $id =~ /^\d+$/;

    if (!defined($rados)) {
	$rados = PVE::RADOS->new();
    }

    my $ccname = PVE::Ceph::Tools::get_config('ccname');
    my $service_dir = "/var/lib/ceph/mds/$ccname-$id";
    my $service_keyring = "$service_dir/keyring";
    my $service_name = "mds.$id";

    die "ceph MDS directory '$service_dir' already exists\n"
	if -d $service_dir;

    print "creating MDS directory '$service_dir'\n";
    eval { File::Path::mkpath($service_dir) };
    my $err = $@;
    die "creation MDS directory '$service_dir' failed\n" if $err;

    # http://docs.ceph.com/docs/luminous/install/manual-deployment/#adding-mds
    my $priv = [
	mon => 'allow profile mds',
	osd => 'allow rwx',
	mds => 'allow *',
    ];

    print "creating keys for '$service_name'\n";
    my $output = $rados->mon_command({
	prefix => 'auth get-or-create',
	entity => $service_name,
	caps => $priv,
	format => 'plain',
    });

    PVE::Tools::file_set_contents($service_keyring, $output);

    print "setting ceph as owner for service directory\n";
    run_command(["chown", 'ceph:ceph', '-R', $service_dir]);

    print "enabling service 'ceph-mds\@$id.service'\n";
    ceph_service_cmd('enable', $service_name);
    print "starting service 'ceph-mds\@$id.service'\n";
    ceph_service_cmd('start', $service_name);

    return undef;
};

sub destroy_mds {
    my ($id, $rados) = @_;

    if (!defined($rados)) {
	$rados = PVE::RADOS->new();
    }

    my $ccname = PVE::Ceph::Tools::get_config('ccname');

    my $service_name = "mds.$id";
    my $service_dir = "/var/lib/ceph/mds/$ccname-$id";

    print "disabling service 'ceph-mds\@$id.service'\n";
    ceph_service_cmd('disable', $service_name);
    print "stopping service 'ceph-mds\@$id.service'\n";
    ceph_service_cmd('stop', $service_name);

    if (-d $service_dir) {
	print "removing ceph-mds directory '$service_dir'\n";
	File::Path::remove_tree($service_dir);
    } else {
	warn "cannot cleanup MDS $id directory, '$service_dir' not found\n"
    }

    print "removing ceph auth for '$service_name'\n";
    $rados->mon_command({
	    prefix => 'auth del',
	    entity => $service_name,
	    format => 'plain'
	});

    return undef;
};

1;
