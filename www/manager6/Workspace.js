/*
 * Workspace base class
 *
 * popup login window when auth fails (call onLogin handler)
 * update (re-login) ticket every 15 minutes
 *
 */

Ext.define('PVE.Workspace', {
    extend: 'Ext.container.Viewport',

    title: 'Proxmox Virtual Environment',

    loginData: null, // Data from last login call

    onLogin: function(loginData) {
	// override me
    },

    // private
    updateLoginData: function(loginData) {
	let me = this;
	me.loginData = loginData;
	Proxmox.Utils.setAuthData(loginData);

	let rt = me.down('pveResourceTree');
	rt.setDatacenterText(loginData.clustername);
	PVE.ClusterName = loginData.clustername;

	if (loginData.cap) {
	    Ext.state.Manager.set('GuiCap', loginData.cap);
	}
	me.response401count = 0;

	me.onLogin(loginData);
    },

    // private
    showLogin: function() {
	let me = this;

	Proxmox.Utils.authClear();
	Ext.state.Manager.clear('GuiCap');
	Proxmox.UserName = null;
	me.loginData = null;

	if (!me.login) {
	    me.login = Ext.create('PVE.window.LoginWindow', {
		handler: function(data) {
		    me.login = null;
		    me.updateLoginData(data);
		    Proxmox.Utils.checked_command(Ext.emptyFn); // display subscription status
		},
	    });
	}
	me.onLogin(null);
        me.login.show();
    },

    initComponent: function() {
	let me = this;

	Ext.tip.QuickTipManager.init();

	// fixme: what about other errors
	Ext.Ajax.on('requestexception', function(conn, response, options) {
	    if ((response.status === 401 || response.status === '401') && !PVE.Utils.silenceAuthFailures) { // auth failure
		// don't immediately show as logged out to cope better with some big
		// upgrades, which may temporarily produce a false positive 401 err
		me.response401count++;
		if (me.response401count > 5) {
		    me.showLogin();
		}
	    }
	});

	me.callParent();

        if (!Proxmox.Utils.authOK()) {
	    me.showLogin();
	} else if (me.loginData) {
	    me.onLogin(me.loginData);
	}

	Ext.TaskManager.start({
	    run: function() {
		let ticket = Proxmox.Utils.authOK();
		if (!ticket || !Proxmox.UserName) {
		    return;
		}

		Ext.Ajax.request({
		    params: {
			username: Proxmox.UserName,
			password: ticket,
		    },
		    url: '/api2/json/access/ticket',
		    method: 'POST',
		    success: function(response, opts) {
			let obj = Ext.decode(response.responseText);
			me.updateLoginData(obj.data);
		    },
		});
	    },
	    interval: 15 * 60 * 1000,
	});
    },
});

Ext.define('PVE.StdWorkspace', {
    extend: 'PVE.Workspace',

    alias: ['widget.pveStdWorkspace'],

    // private
    setContent: function(comp) {
	let me = this;

	let view = me.child('#content');
	let layout = view.getLayout();
	let current = layout.getActiveItem();

	if (comp) {
	    Proxmox.Utils.setErrorMask(view, false);
	    comp.border = false;
	    view.add(comp);
	    if (current !== null && layout.getNext()) {
		layout.next();
		let task = Ext.create('Ext.util.DelayedTask', function() {
		    view.remove(current);
		});
		task.delay(10);
	    }
	} else {
	    view.removeAll(); // helper for cleaning the content when logging out
	}
    },

    selectById: function(nodeid) {
	let me = this;
	me.down('pveResourceTree').selectById(nodeid);
    },

    onLogin: function(loginData) {
	let me = this;

	me.updateUserInfo();

	if (loginData) {
	    PVE.data.ResourceStore.startUpdate();

	    Proxmox.Utils.API2Request({
		url: '/version',
		method: 'GET',
		success: function(response) {
		    PVE.VersionInfo = response.result.data;
		    me.updateVersionInfo();
		},
	    });

	    Proxmox.Utils.API2Request({
		url: '/cluster/sdn',
		method: 'GET',
		success: function(response) {
		    PVE.SDNInfo = response.result.data;
		},
		failure: function(response) {
		    PVE.SDNInfo = null;
		    let ui = Ext.ComponentQuery.query('treelistitem[text="SDN"]')[0];
		    if (ui) {
			ui.addCls('x-hidden-display');
		    }
		},
	    });
	}
    },

    updateUserInfo: function() {
	let me = this;
	let ui = me.query('#userinfo')[0];
	ui.setText(Ext.String.htmlEncode(Proxmox.UserName || ''));
	ui.updateLayout();
    },

    updateVersionInfo: function() {
	let me = this;

	let ui = me.query('#versioninfo')[0];

	if (PVE.VersionInfo) {
	    let version = PVE.VersionInfo.version;
	    ui.update('Virtual Environment ' + version);
	} else {
	    ui.update('Virtual Environment');
	}
	ui.updateLayout();
    },

    initComponent: function() {
	let me = this;

	Ext.History.init();

	let appState = Ext.create('PVE.StateProvider');
	Ext.state.Manager.setProvider(appState);

	let selview = Ext.create('PVE.form.ViewSelector');

	let rtree = Ext.createWidget('pveResourceTree', {
	    viewFilter: selview.getViewFilter(),
	    flex: 1,
	    selModel: {
		selType: 'treemodel',
		listeners: {
		    selectionchange: function(sm, selected) {
			if (selected.length <= 0) {
			    return;
			}
			let treeNode = selected[0];
			let treeTypeToClass = {
			    root: 'PVE.dc.Config',
			    node: 'PVE.node.Config',
			    qemu: 'PVE.qemu.Config',
			    lxc: 'PVE.lxc.Config',
			    storage: 'PVE.storage.Browser',
			    sdn: 'PVE.sdn.Browser',
			    pool: 'pvePoolConfig',
			};
			PVE.curSelectedNode = treeNode;
			me.setContent({
			    xtype: treeTypeToClass[treeNode.data.type || 'root'] || 'pvePanelConfig',
			    showSearch: treeNode.data.id === 'root' || Ext.isDefined(treeNode.data.groupbyid),
			    pveSelNode: treeNode,
			    workspace: me,
			    viewFilter: selview.getViewFilter(),
			});
		    },
		},
	    },
	});

	selview.on('select', function(combo, records) {
	    if (records) {
		let view = combo.getViewFilter();
		rtree.setViewFilter(view);
	    }
	});

	let caps = appState.get('GuiCap');

	let createVM = Ext.createWidget('button', {
	    pack: 'end',
	    margin: '3 5 0 0',
	    baseCls: 'x-btn',
	    iconCls: 'fa fa-desktop',
	    text: gettext("Create VM"),
	    disabled: !caps.vms['VM.Allocate'],
	    handler: function() {
		let wiz = Ext.create('PVE.qemu.CreateWizard', {});
		wiz.show();
	    },
	});

	let createCT = Ext.createWidget('button', {
	    pack: 'end',
	    margin: '3 5 0 0',
	    baseCls: 'x-btn',
	    iconCls: 'fa fa-cube',
	    text: gettext("Create CT"),
	    disabled: !caps.vms['VM.Allocate'],
	    handler: function() {
		let wiz = Ext.create('PVE.lxc.CreateWizard', {});
		wiz.show();
	    },
	});

	appState.on('statechange', function(sp, key, value) {
	    if (key === 'GuiCap' && value) {
		caps = value;
		createVM.setDisabled(!caps.vms['VM.Allocate']);
		createCT.setDisabled(!caps.vms['VM.Allocate']);
	    }
	});

	Ext.apply(me, {
	    layout: { type: 'border' },
	    border: false,
	    items: [
		{
		    region: 'north',
		    layout: {
			type: 'hbox',
			align: 'middle',
		    },
		    baseCls: 'x-plain',
		    defaults: {
			baseCls: 'x-plain',
		    },
		    border: false,
		    margin: '2 0 2 5',
		    items: [
			{
			    xtype: 'proxmoxlogo',
			},
			{
			    minWidth: 150,
			    id: 'versioninfo',
			    html: 'Virtual Environment',
			},
			{
			    xtype: 'pveGlobalSearchField',
			    tree: rtree,
			},
			{
			    flex: 1,
			},
			{
			    xtype: 'proxmoxEOLNotice',
			    product: 'Proxmox VE',
			    version: '6.4',
			    eolDate: '2022-07-31',
			    href: 'pve.proxmox.com/wiki/FAQ#faq-support-table',
			},
			{
			    flex: 1
			},
			{
			    xtype: 'proxmoxHelpButton',
			    hidden: false,
			    baseCls: 'x-btn',
			    iconCls: 'fa fa-book x-btn-icon-el-default-toolbar-small ',
			    listenToGlobalEvent: false,
			    onlineHelp: 'pve_documentation_index',
			    text: gettext('Documentation'),
			    margin: '0 5 0 0',
			},
			createVM,
			createCT,
			{
			    pack: 'end',
			    margin: '0 5 0 0',
			    id: 'userinfo',
			    xtype: 'button',
			    baseCls: 'x-btn',
			    style: {
				// proxmox dark grey p light grey as border
				backgroundColor: '#464d4d',
				borderColor: '#ABBABA',
			    },
			    iconCls: 'fa fa-user',
			    menu: [
				{
				    iconCls: 'fa fa-gear',
				    text: gettext('My Settings'),
				    handler: function() {
					var win = Ext.create('PVE.window.Settings');
					win.show();
				    },
				},
				{
				    text: gettext('Password'),
				    iconCls: 'fa fa-fw fa-key',
				    handler: function() {
					var win = Ext.create('Proxmox.window.PasswordEdit', {
					    userid: Proxmox.UserName,
					});
					win.show();
				    },
				},
				{
				    text: 'TFA',
				    iconCls: 'fa fa-fw fa-lock',
				    handler: function(btn, event, rec) {
					var win = Ext.create('PVE.window.TFAEdit', {
					    userid: Proxmox.UserName,
					});
					win.show();
				    },
				},
				{
				    iconCls: 'fa fa-language',
				    text: gettext('Language'),
				    handler: function() {
					Ext.create('Proxmox.window.LanguageEditWindow')
					    .show();
				    },
				},
				'-',
				{
				    iconCls: 'fa fa-fw fa-sign-out',
				    text: gettext("Logout"),
				    handler: function() {
					PVE.data.ResourceStore.loadData([], false);
					me.showLogin();
					me.setContent(null);
					var rt = me.down('pveResourceTree');
					rt.setDatacenterText(undefined);
					rt.clearTree();

					// empty the stores of the StatusPanel child items
					var statusPanels = Ext.ComponentQuery.query('pveStatusPanel grid');
					Ext.Array.forEach(statusPanels, function(comp) {
					    if (comp.getStore()) {
						comp.getStore().loadData([], false);
					    }
					});
				    },
				},
			    ],
			},
		    ],
		},
		{
		    region: 'center',
		    stateful: true,
		    stateId: 'pvecenter',
		    minWidth: 100,
		    minHeight: 100,
		    id: 'content',
		    xtype: 'container',
		    layout: { type: 'card' },
		    border: false,
		    margin: '0 5 0 0',
		    items: [],
		},
		{
		    region: 'west',
		    stateful: true,
		    stateId: 'pvewest',
		    itemId: 'west',
		    xtype: 'container',
		    border: false,
		    layout: { type: 'vbox', align: 'stretch' },
		    margin: '0 0 0 5',
		    split: true,
		    width: 200,
		    items: [selview, rtree],
		    listeners: {
			resize: function(panel, width, height) {
			    var viewWidth = me.getSize().width;
			    if (width > viewWidth - 100) {
				panel.setWidth(viewWidth - 100);
			    }
			},
		    },
		},
		{
		    xtype: 'pveStatusPanel',
		    stateful: true,
		    stateId: 'pvesouth',
		    itemId: 'south',
		    region: 'south',
		    margin: '0 5 5 5',
		    title: gettext('Logs'),
		    collapsible: true,
		    header: false,
		    height: 200,
		    split: true,
		    listeners: {
			resize: function(panel, width, height) {
			    var viewHeight = me.getSize().height;
			    if (height > viewHeight - 150) {
				panel.setHeight(viewHeight - 150);
			    }
			},
		    },
		},
	    ],
	});

	me.callParent();

	me.updateUserInfo();

	// on resize, center all modal windows
	Ext.on('resize', function() {
	    let modalWindows = Ext.ComponentQuery.query('window[modal]');
	    if (modalWindows.length > 0) {
		modalWindows.forEach(win => win.alignTo(me, 'c-c'));
	    }
	});
    },
});

