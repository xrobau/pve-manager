package PVE::CLI::pvenode;

use strict;
use warnings;

use PVE::API2::ACME;
use PVE::API2::ACMEAccount;
use PVE::API2::Certificates;
use PVE::API2::NodeConfig;
use PVE::API2::Nodes;
use PVE::API2::Tasks;

use PVE::CertHelpers;
use PVE::Certificate;
use PVE::Exception qw(raise_param_exc raise);
use PVE::JSONSchema qw(get_standard_option);
use PVE::NodeConfig;
use PVE::RPCEnvironment;
use PVE::CLIFormatter;
use PVE::RESTHandler;
use PVE::CLIHandler;

use Term::ReadLine;

use base qw(PVE::CLIHandler);

my $nodename = PVE::INotify::nodename();

sub setup_environment {
    PVE::RPCEnvironment->setup_default_cli_env();
}

my $upid_exit = sub {
    my $upid = shift;
    my $status = PVE::Tools::upid_read_status($upid);
    print "Task $status\n";
    exit($status eq 'OK' ? 0 : -1);
};

sub param_mapping {
    my ($name) = @_;

    my $mapping = {
	'upload_custom_cert' => [
	    'certificates',
	    'key',
	],
    };

    return $mapping->{$name};
}

__PACKAGE__->register_method({
    name => 'acme_register',
    path => 'acme_register',
    method => 'POST',
    description => "Register a new ACME account with a compatible CA.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    name => get_standard_option('pve-acme-account-name'),
	    contact => get_standard_option('pve-acme-account-contact'),
	    directory => get_standard_option('pve-acme-directory-url', {
		optional => 1,
	    }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	if (!$param->{directory}) {
	    my $directories = PVE::API2::ACMEAccount->get_directories({});
	    print "Directory endpoints:\n";
	    my $i = 0;
	    while ($i < @$directories) {
		print $i, ") ", $directories->[$i]->{name}, " (", $directories->[$i]->{url}, ")\n";
		$i++;
	    }
	    print $i, ") Custom\n";

	    my $term = Term::ReadLine->new('pvenode');
	    my $get_dir_selection = sub {
		my $selection = $term->readline("Enter selection:\n");
		if ($selection =~ /^(\d+)$/) {
		    $selection = $1;
		    if ($selection == $i) {
			$param->{directory} = $term->readline("Enter URL:\n");
			return;
		    } elsif ($selection < $i && $selection >= 0) {
			$param->{directory} = $directories->[$selection]->{url};
			return;
		    }
		}
		print "Invalid selection.\n";
	    };

	    my $attempts = 0;
	    while (!$param->{directory}) {
		die "Aborting.\n" if $attempts > 3;
		$get_dir_selection->();
		$attempts++;
	    }
	}
	print "\nAttempting to fetch Terms of Service from '$param->{directory}'..\n";
	my $tos = PVE::API2::ACMEAccount->get_tos({ directory => $param->{directory} });
	if ($tos) {
	    print "Terms of Service: $tos\n";
	    my $term = Term::ReadLine->new('pvenode');
	    my $agreed = $term->readline('Do you agree to the above terms? [y|N]');
	    die "Cannot continue without agreeing to ToS, aborting.\n"
		if ($agreed !~ /^y$/i);

	    $param->{tos_url} = $tos;
	} else {
	    print "No Terms of Service found, proceeding.\n";
	}
	print "\nAttempting to register account with '$param->{directory}'..\n";

	$upid_exit->(PVE::API2::ACMEAccount->register_account($param));
    }});

my $print_cert_info = sub {
    my ($schema, $cert, $options) = @_;

    my $order = [qw(filename fingerprint subject issuer notbefore notafter public-key-type public-key-bits san)];
    PVE::CLIFormatter::print_api_result(
	$cert, $schema, $order, { %$options, noheader => 1, sort_key => 0 });
};

our $cmddef = {
    config => {
	get => [ 'PVE::API2::NodeConfig', 'get_config', [], { node => $nodename }, sub {
	    my ($res) = @_;
	    print PVE::NodeConfig::write_node_config($res);
	}],
        set => [ 'PVE::API2::NodeConfig', 'set_options', [], { node => $nodename } ],
    },

    startall => [ 'PVE::API2::Nodes::Nodeinfo', 'startall', [], { node => $nodename } ],
    stopall => [ 'PVE::API2::Nodes::Nodeinfo', 'stopall', [], { node => $nodename } ],
    migrateall => [ 'PVE::API2::Nodes::Nodeinfo', 'migrateall', [ 'target' ], { node => $nodename } ],

    cert => {
	info => [ 'PVE::API2::Certificates', 'info', [], { node => $nodename }, sub {
	    my ($res, $schema, $options) = @_;

	    if (!$options->{'output-format'} || $options->{'output-format'} eq 'text') {
		for my $cert (sort { $a->{filename} cmp $b->{filename} } @$res) {
		    $print_cert_info->($schema->{items}, $cert, $options);
		}
	    } else {
		PVE::CLIFormatter::print_api_result($res, $schema, undef, $options);
	    }

	}, $PVE::RESTHandler::standard_output_options],
	set => [ 'PVE::API2::Certificates', 'upload_custom_cert', ['certificates', 'key'], { node => $nodename }, sub {
	    my ($res, $schema, $options) = @_;
	    $print_cert_info->($schema, $res, $options);
	}, $PVE::RESTHandler::standard_output_options],
	delete => [ 'PVE::API2::Certificates', 'remove_custom_cert', ['restart'], { node => $nodename } ],
    },

    task => {
	list => [ 'PVE::API2::Tasks', 'node_tasks', [], { node => $nodename }, sub {
	    my ($data, $schema, $options) = @_;
	    foreach my $task (@$data) {
		if (!defined($task->{status})) {
		    $task->{status} = 'UNKNOWN';
		} elsif ($task->{status} ne 'OK' && $task->{status} ne 'RUNNING') {
		    $task->{status} = 'ERROR';
		}
	    }
	    PVE::CLIFormatter::print_api_result($data, $schema, ['upid', 'type', 'id', 'user', 'starttime', 'endtime', 'status' ], $options);
	}, $PVE::RESTHandler::standard_output_options],
	status => [ 'PVE::API2::Tasks', 'read_task_status', [ 'upid' ], { node => $nodename }, sub {
	    my ($data, $schema, $options) = @_;
	    PVE::CLIFormatter::print_api_result($data, $schema, undef, $options);
	}, $PVE::RESTHandler::standard_output_options],
	# set limit to 1000000, so we see the whole log, not only the first 50 lines by default
	log => [ 'PVE::API2::Tasks', 'read_task_log', [ 'upid' ], { node => $nodename, limit => 1000000 }, sub {
	    my ($data, $resultprops) = @_;
	    foreach my $line (@$data) {
		print $line->{t} . "\n";
	    }
	}],
    },

    acme => {
	account => {
	    list => [ 'PVE::API2::ACMEAccount', 'account_index', [], {}, sub {
		my ($res) = @_;
		for my $acc (@$res) {
		    print "$acc->{name}\n";
		}
	    }],
	    register => [ __PACKAGE__, 'acme_register', ['name', 'contact'], {}, $upid_exit ],
	    deactivate => [ 'PVE::API2::ACMEAccount', 'deactivate_account', ['name'], {}, $upid_exit ],
	    info => [ 'PVE::API2::ACMEAccount', 'get_account', ['name'], {}, sub {
		my ($data, $schema, $options) = @_;
		PVE::CLIFormatter::print_api_result($data, $schema, undef, $options);
	    }, $PVE::RESTHandler::standard_output_options],
	    update => [ 'PVE::API2::ACMEAccount', 'update_account', ['name'], {}, $upid_exit ],
	},
	cert => {
	    order => [ 'PVE::API2::ACME', 'new_certificate', [], { node => $nodename }, $upid_exit ],
	    renew => [ 'PVE::API2::ACME', 'renew_certificate', [], { node => $nodename }, $upid_exit ],
	    revoke => [ 'PVE::API2::ACME', 'revoke_certificate', [], { node => $nodename }, $upid_exit ],
	},
    },

    wakeonlan => [ 'PVE::API2::Nodes::Nodeinfo', 'wakeonlan', [ 'node' ], {}, sub {
	    my ($mac_addr) = @_;

	    print "Wake on LAN packet send for '$mac_addr'\n";
	} ],

};

1;
