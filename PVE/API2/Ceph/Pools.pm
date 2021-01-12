package PVE::API2::Ceph::Pools;

use strict;
use warnings;

use PVE::Ceph::Tools;
use PVE::Ceph::Services;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RADOS;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Storage;
use PVE::Tools qw(extract_param);

use PVE::API2::Storage::Config;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method ({
    name => 'lspools',
    path => '',
    method => 'GET',
    description => "List all pools.",
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit', 'Datastore.Audit' ], any => 1],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		pool => { type => 'integer', title => 'ID' },
		pool_name => { type => 'string', title => 'Name' },
		size => { type => 'integer', title => 'Size' },
		min_size => { type => 'integer', title => 'Min Size' },
		pg_num => { type => 'integer', title => 'PG Num' },
		pg_autoscale_mode => { type => 'string', optional => 1, title => 'PG Autoscale Mode' },
		crush_rule => { type => 'integer', title => 'Crush Rule' },
		crush_rule_name => { type => 'string', title => 'Crush Rule Name' },
		percent_used => { type => 'number', title => '%-Used' },
		bytes_used => { type => 'integer', title => 'Used' },
	    },
	},
	links => [ { rel => 'child', href => "{pool_name}" } ],
    },
    code => sub {
	my ($param) = @_;

	PVE::Ceph::Tools::check_ceph_inited();

	my $rados = PVE::RADOS->new();

	my $stats = {};
	my $res = $rados->mon_command({ prefix => 'df' });

	foreach my $d (@{$res->{pools}}) {
	    next if !$d->{stats};
	    next if !defined($d->{id});
	    $stats->{$d->{id}} = $d->{stats};
	}

	$res = $rados->mon_command({ prefix => 'osd dump' });
	my $rulestmp = $rados->mon_command({ prefix => 'osd crush rule dump'});

	my $rules = {};
	for my $rule (@$rulestmp) {
	    $rules->{$rule->{rule_id}} = $rule->{rule_name};
	}

	my $data = [];
	my $attr_list = [
	    'pool',
	    'pool_name',
	    'size',
	    'min_size',
	    'pg_num',
	    'crush_rule',
	    'pg_autoscale_mode',
	];

	foreach my $e (@{$res->{pools}}) {
	    my $d = {};
	    foreach my $attr (@$attr_list) {
		$d->{$attr} = $e->{$attr} if defined($e->{$attr});
	    }

	    if (defined($d->{crush_rule}) && defined($rules->{$d->{crush_rule}})) {
		$d->{crush_rule_name} = $rules->{$d->{crush_rule}};
	    }

	    if (my $s = $stats->{$d->{pool}}) {
		$d->{bytes_used} = $s->{bytes_used};
		$d->{percent_used} = $s->{percent_used};
	    }
	    push @$data, $d;
	}


	return $data;
    }});


my $ceph_pool_common_options = sub {
    my ($nodefault) = shift;
    my $options = {
	name => {
	    description => "The name of the pool. It must be unique.",
	    type => 'string',
	},
	size => {
	    description => 'Number of replicas per object',
	    type => 'integer',
	    default => 3,
	    optional => 1,
	    minimum => 1,
	    maximum => 7,
	},
	min_size => {
	    description => 'Minimum number of replicas per object',
	    type => 'integer',
	    default => 2,
	    optional => 1,
	    minimum => 1,
	    maximum => 7,
	},
	pg_num => {
	    description => "Number of placement groups.",
	    type => 'integer',
	    default => 128,
	    optional => 1,
	    minimum => 8,
	    maximum => 32768,
	},
	crush_rule => {
	    description => "The rule to use for mapping object placement in the cluster.",
	    type => 'string',
	    optional => 1,
	},
	application => {
	    description => "The application of the pool.",
	    default => 'rbd',
	    type => 'string',
	    enum => ['rbd', 'cephfs', 'rgw'],
	    optional => 1,
	},
	pg_autoscale_mode => {
	    description => "The automatic PG scaling mode of the pool.",
	    type => 'string',
	    enum => ['on', 'off', 'warn'],
	    default => 'warn',
	    optional => 1,
	},
    };

    if ($nodefault) {
	delete $options->{$_}->{default} for keys %$options;
    }
    return $options;
};


my $add_storage = sub {
    my ($pool, $storeid) = @_;

    my $storage_params = {
	type => 'rbd',
	pool => $pool,
	storage => $storeid,
	krbd => 0,
	content => 'rootdir,images',
    };

    PVE::API2::Storage::Config->create($storage_params);
};

my $get_storages = sub {
    my ($pool) = @_;

    my $cfg = PVE::Storage::config();

    my $storages = $cfg->{ids};
    my $res = {};
    foreach my $storeid (keys %$storages) {
	my $curr = $storages->{$storeid};
	$res->{$storeid} = $storages->{$storeid}
	    if $curr->{type} eq 'rbd' && $pool eq $curr->{pool};
    }

    return $res;
};


__PACKAGE__->register_method ({
    name => 'createpool',
    path => '',
    method => 'POST',
    description => "Create POOL",
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    add_storages => {
		description => "Configure VM and CT storage using the new pool.",
		type => 'boolean',
		optional => 1,
	    },
	    %{ $ceph_pool_common_options->() },
	},
    },
    returns => { type => 'string' },
    code => sub {
	my ($param) = @_;

	PVE::Cluster::check_cfs_quorum();
	PVE::Ceph::Tools::check_ceph_configured();

	my $pool = extract_param($param, 'name');
	my $node = extract_param($param, 'node');
	my $add_storages = extract_param($param, 'add_storages');

	my $rpcenv = PVE::RPCEnvironment::get();
	my $user = $rpcenv->get_user();

	if ($add_storages) {
	    $rpcenv->check($user, '/storage', ['Datastore.Allocate']);
	    die "pool name contains characters which are illegal for storage naming\n"
		if !PVE::JSONSchema::parse_storage_id($pool);
	}

	# pool defaults
	$param->{pg_num} //= 128;
	$param->{size} //= 3;
	$param->{min_size} //= 2;
	$param->{application} //= 'rbd';
	$param->{pg_autoscale_mode} //= 'warn';

	my $worker = sub {

	    PVE::Ceph::Tools::create_pool($pool, $param);

	    if ($add_storages) {
		my $err;
		eval { $add_storage->($pool, "${pool}"); };
		if ($@) {
		    warn "failed to add storage: $@";
		    $err = 1;
		}
		die "adding storage for pool '$pool' failed, check log and add manually!\n"
		    if $err;
	    }
	};

	return $rpcenv->fork_worker('cephcreatepool', $pool,  $user, $worker);
    }});


__PACKAGE__->register_method ({
    name => 'destroypool',
    path => '{name}',
    method => 'DELETE',
    description => "Destroy pool",
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    name => {
		description => "The name of the pool. It must be unique.",
		type => 'string',
	    },
	    force => {
		description => "If true, destroys pool even if in use",
		type => 'boolean',
		optional => 1,
		default => 0,
	    },
	    remove_storages => {
		description => "Remove all pveceph-managed storages configured for this pool",
		type => 'boolean',
		optional => 1,
		default => 0,
	    },
	},
    },
    returns => { type => 'string' },
    code => sub {
	my ($param) = @_;

	PVE::Ceph::Tools::check_ceph_inited();

	my $rpcenv = PVE::RPCEnvironment::get();
	my $user = $rpcenv->get_user();
	$rpcenv->check($user, '/storage', ['Datastore.Allocate'])
	    if $param->{remove_storages};

	my $pool = $param->{name};

	my $worker = sub {
	    my $storages = $get_storages->($pool);

	    # if not forced, destroy ceph pool only when no
	    # vm disks are on it anymore
	    if (!$param->{force}) {
		my $storagecfg = PVE::Storage::config();
		foreach my $storeid (keys %$storages) {
		    my $storage = $storages->{$storeid};

		    # check if any vm disks are on the pool
		    print "checking storage '$storeid' for RBD images..\n";
		    my $res = PVE::Storage::vdisk_list($storagecfg, $storeid);
		    die "ceph pool '$pool' still in use by storage '$storeid'\n"
			if @{$res->{$storeid}} != 0;
		}
	    }

	    PVE::Ceph::Tools::destroy_pool($pool);

	    if ($param->{remove_storages}) {
		my $err;
		foreach my $storeid (keys %$storages) {
		    # skip external clusters, not managed by pveceph
		    next if $storages->{$storeid}->{monhost};
		    eval { PVE::API2::Storage::Config->delete({storage => $storeid}) };
		    if ($@) {
			warn "failed to remove storage '$storeid': $@\n";
			$err = 1;
		    }
		}
		die "failed to remove (some) storages - check log and remove manually!\n"
		    if $err;
	    }
	};
	return $rpcenv->fork_worker('cephdestroypool', $pool,  $user, $worker);
    }});


__PACKAGE__->register_method ({
    name => 'setpool',
    path => '{name}',
    method => 'PUT',
    description => "Change POOL settings",
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', [ 'Sys.Modify' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    %{ $ceph_pool_common_options->('nodefault') },
	},
    },
    returns => { type => 'string' },
    code => sub {
	my ($param) = @_;

	PVE::Ceph::Tools::check_ceph_configured();

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

	my $pool = $param->{name};
	my $ceph_param = \%$param;
	for my $item ('name', 'node') {
	    # not ceph parameters
	    delete $ceph_param->{$item};
	}

	my $worker = sub {
	    PVE::Ceph::Tools::set_pool($pool, $ceph_param);
	};

	return $rpcenv->fork_worker('cephsetpool', $pool,  $authuser, $worker);
    }});


1;
