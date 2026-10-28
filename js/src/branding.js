/* Módulo branding — identidade visual (plano: "Módulo branding").
 *
 * (a) MM.Branding.init(): lê /pve2/js/mm-branding.json (gravado pelo apply)
 *     e sobrescreve logo/favicon/título/texto do topo/texto de login.
 *     "Powered by Proxmox VE" permanece visível (regra do plano).
 * (b) Aba Branding (MM.registerTab): upload base64 via API, textos,
 *     pré-visualização, Salvar/Restaurar padrão.
 */

Ext.define('MM.Branding', {
    singleton: true,

    cfg: null,

    /* Chamado no boot do mm-tools.js (e de novo depois de cada apply). */
    init: function () {
	let me = this;
	fetch('/pve2/js/mm-branding.json?v=' + Date.now())
	    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
	    .then((cfg) => me.apply(cfg))
	    .catch(() => me.clear());    // sem branding: volta ao padrão do PVE
    },

    apply: function (cfg) {
	let me = this;
	if (!cfg || typeof cfg !== 'object') { me.clear(); return; }
	me.cfg = cfg;

	// Logo do topo (PMX.image.LogoSVG, refs/upstream/pwt-Logo.js):
	// o initComponent prefixa '/pve2' no src; sobrescrevemos depois de
	// criado via override que roda depois do callParent.
	if (cfg.logo_url) {
	    Ext.define('MM.override.LogoSVG', {
		override: 'PMX.image.LogoSVG',
		initComponent: function () {
		    let me2 = this;
		    me2.callParent(arguments);
		    if (MM.Branding.cfg?.logo_url) {
			me2.setSrc(MM.Branding.cfg.logo_url);
			me2.autoEl = Ext.apply({}, me2.autoEl, { tag: 'div' }); // sem link externo
		    }
		},
	    });
	    // componentes já renderizados
	    Ext.ComponentQuery.query('proxmoxLogoSvg').forEach((c) => {
		c.setSrc(cfg.logo_url);
	    });
	}

	// Favicon e apple-touch-icon (index.html.tpl usa logo-128.png)
	if (cfg.favicon_url) {
	    document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]').forEach((l) => {
		l.href = cfg.favicon_url;
	    });
	}

	// Título da aba: mantém o nome do node ("node — Título")
	if (cfg.title) {
	    let base = document.title;
	    let node = base.split('-')[0]?.trim() || window.location.hostname;
	    document.title = `${node} - ${cfg.title}`;
	}

	// Texto do topo (itemId versioninfo "Virtual Environment <versão>"):
	// mantém a versão do PVE visível.
	if (cfg.header_text) {
	    let setHeader = () => {
		Ext.ComponentQuery.query('#versioninfo').forEach((c) => {
		    let cur = c.getValue ? c.getValue() : (c.getHtml?.() ?? '');
	    let m = String(cur ?? '').match(/\d[\w.-]*/);    // versão
		    let txt = cfg.header_text + (m ? ` ${m[0]}` : '');
		    if (c.setValue) { c.setValue(txt); } else { c.setHtml(txt); }
		});
	    };
	    setHeader();
	    // janelas/views criadas depois
	    Ext.on('resize', setHeader);
	}

	// Tela de login: mostra login_text abaixo do logo, sem esconder o
	// branding do Proxmox.
	if (cfg.login_text && Ext.ClassManager.get('PVE.window.LoginWindow')) {
	    Ext.define('MM.override.LoginWindow', {
		override: 'PVE.window.LoginWindow',
		initComponent: function () {
		    let me2 = this;
		    me2.callParent(arguments);
		    let items = me2.items;
		    if (items && items.length && cfg.logo_url) {
			// substitui o logo do login pelo da MasterMind
			Ext.each(items, (it) => {
			    if (it.xtype === 'proxmoxLogoSvg' || it.xtype === 'proxmoxlogo') {
				it.src = cfg.logo_url.replace(/^\/pve2/, '');
			    }
			});
		    }
		    let panel = items?.[0];
		    if (panel) {
			panel.items = (panel.items || []).concat([{
			    xtype: 'box',
			    html: Ext.String.htmlEncode(cfg.login_text),
			    padding: '5 0',
			    style: { 'text-align': 'center', color: '#555' },
			}, {
			    xtype: 'box',
			    html: 'Powered by Proxmox VE',
			    padding: '2 0 5 0',
			    style: { 'text-align': 'center', 'font-size': '11px', color: '#888' },
			}]);
		    }
		},
	    });
	}
    },

    /* Sem branding.json (revert): devolve favicon/título ao padrão. */
    clear: function () {
	let me = this;
	if (!me.cfg) { return; }
	me.cfg = null;
	document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]').forEach((l) => {
	    l.href = '/pve2/images/logo-128.png';
	});
    },
});

MM.Branding.init();

/* ------------------------- Aba Branding ------------------------- */

Ext.define('MM.panel.Branding', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.mmPanelBranding',
    title: gettext('Branding'),
    layout: 'fit',

    initComponent: function () {
	let me = this;

	let readFile = (file, cb) => {
	    let fr = new FileReader();
	    fr.onload = () => cb(String(fr.result).split(',').pop()); // base64 puro
	    fr.readAsDataURL(file);
	};

	let logoField = Ext.create('Ext.form.field.File', {
	    fieldLabel: gettext('Logo') + ' (SVG/PNG, 200 KB)',
	    name: 'logo',
	    accept: '.svg,.png',
	    listeners: {
		change: (f, v) => {
		    me.pendingLogoName = f.fileInputEl.dom.files[0]?.name;
		    readFile(f.fileInputEl.dom.files[0], (b64) => { me.pendingLogo = b64; me.preview(); });
		    void v;
		},
	    },
	});
	let faviconField = Ext.create('Ext.form.field.File', {
	    fieldLabel: gettext('Favicon') + ' (SVG/PNG, 200 KB)',
	    name: 'favicon',
	    accept: '.svg,.png',
	    listeners: {
		change: (f) => {
		    me.pendingFaviconName = f.fileInputEl.dom.files[0]?.name;
		    readFile(f.fileInputEl.dom.files[0], (b64) => { me.pendingFavicon = b64; me.preview(); });
		},
	    },
	});
	let titleField = Ext.create('Ext.form.field.Text', {
	    fieldLabel: gettext('Title'), name: 'title', maxLength: 100,
	});
	let headerField = Ext.create('Ext.form.field.Text', {
	    fieldLabel: gettext('Header text'), name: 'header_text', maxLength: 60,
	});
	let loginField = Ext.create('Ext.form.field.TextArea', {
	    fieldLabel: gettext('Login text'), name: 'login_text', maxLength: 200,
	});

	let previewBox = Ext.create('Ext.Component', {
	    autoEl: 'div',
	    padding: 10,
	    html: '-',
	});

	me.preview = function () {
	    let src = null;
	    if (me.pendingLogo) {
		let ext = (me.pendingLogoName || 'x.svg').split('.').pop().toLowerCase();
		src = `data:image/${ext === 'png' ? 'png' : 'svg+xml'};base64,${me.pendingLogo}`;
	    } else if (me.state?.branding?.logo) {
		src = `/pve2/images/mm-branding/${me.state.branding.logo}?v=${me.state.state?.config_hash || '0'}`;
	    }
	    previewBox.setHtml(src
		? `<img src="${src}" style="max-height:60px;max-width:260px" alt="logo"/>`
		: gettext('No logo uploaded'));
	};

	me.reload = function () {
	    MM.Api.request({
		url: '/nodes/localhost/mm-tools/branding',
		success: (res) => {
		    me.state = res;
		    let b = res.branding || {};
		    titleField.setValue(b.title || '');
		    headerField.setValue(b.header_text || '');
		    loginField.setValue(b.login_text || '');
		    me.digest = res.digest;
		    me.preview();
		},
	    });
	};

	let doUpload = (cb) => {
	    if (!me.pendingLogo && !me.pendingFavicon) { cb(); return; }
	    let data = { digest: me.digest };
	    if (me.pendingLogo) {
		data.logo_b64 = me.pendingLogo;
		data.logo_name = me.pendingLogoName;
	    }
	    if (me.pendingFavicon) {
		data.favicon_b64 = me.pendingFavicon;
		data.favicon_name = me.pendingFaviconName;
	    }
	    MM.Api.request({
		method: 'PUT',
		url: '/nodes/localhost/mm-tools/branding/upload',
		data: data,
		success: () => cb(),
		failure: (msg) => Ext.Msg.alert(gettext('Error'), msg),
	    });
	};

	let form = Ext.create('Ext.form.Panel', {
	    layout: { type: 'vbox', align: 'stretch' },
	    bodyPadding: 10,
	    border: false,
	    defaults: { width: '100%' },
	    items: [
		titleField,
		headerField,
		logoField,
		faviconField,
		loginField,
		{ xtype: 'tbspacer', height: 10 },
		{
		    xtype: 'fieldset',
		    title: gettext('Preview'),
		    items: [previewBox],
		},
	    ],
	    buttons: [
		{
		    text: gettext('Save'),
		    iconCls: 'fa fa-fw fa-check',
		    handler: () => {
			if (!form.isValid()) { return; }
			doUpload(() => {
			    MM.Api.request({
				method: 'PUT',
				url: '/nodes/localhost/mm-tools/branding/set',
				data: {
				    title: titleField.getValue(),
				    header_text: headerField.getValue(),
				    login_text: loginField.getValue(),
				},
				success: () => {
				    me.pendingLogo = me.pendingFavicon = null;
				    me.reload();
				    // aplica já neste node (imagens copiadas + json)
				    MM.Api.request({
					method: 'POST',
					url: '/nodes/localhost/mm-tools/apply',
					success: (res) => {
					    if (res?.data) {
						Ext.create('Proxmox.window.TaskViewer', { upid: res.data, autoShow: true });
					    }
					},
				    });
				},
				failure: (msg) => Ext.Msg.alert(gettext('Error'), msg),
			    });
			});
		    },
		},
		{
		    text: gettext('Restore Default'),
		    iconCls: 'fa fa-fw fa-undo',
		    handler: () => {
			MM.Api.request({
			    method: 'PUT',
			    url: '/nodes/localhost/mm-tools/branding/set',
			    data: { digest: me.digest, clear: true },
			    success: () => {
				me.pendingLogo = me.pendingFavicon = null;
				MM.Branding.clear();
				me.reload();
			    },
			    failure: (msg) => Ext.Msg.alert(gettext('Error'), msg),
			});
		    },
		},
	    ],
	});

	Ext.apply(me, { items: [form] });
	me.callParent();
	me.reload();
    },
});

MM.registerTab({ xtype: 'mmPanelBranding', title: gettext('Branding') });
