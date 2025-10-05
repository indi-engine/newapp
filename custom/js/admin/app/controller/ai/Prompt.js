Ext.define('Indi.view.ai.Prompt', {
    extend: 'Ext.container.Container',
    id: 'aiprompt',
    require: [
        'Indi.view.ai.PromptController'
    ],
    xtype: 'aiprompt',
    userCls: 'aiprompt',
    flex: 1,
    layout: {
        type: 'vbox',
        align: 'stretch'
    },
    viewModelCfg: {
        formulas: {
            promptEmptyText: get => get('emptyTextByPurpose')[get('draft.purpose')]
        }
    },
    controller: 'aiprompt',
    items: [
        {
            xtype: 'textarea',
            name: 'prompt',
            reference: 'prompt',
            width: 600,
            value: '',
            grow: true,
            growMax: 300,
            growMin: 30,
            margin: '0 0 6 0',
            padding: '0 0 50 0',
            isCustomField: true,
            enableKeyEvents: true,
            onPaste: (e, dom, opts) => opts.scope.fireEvent('paste', opts.scope, e),
            bind: {
                emptyText: '{promptEmptyText}',
                value: '{draft.prompt}'
            }
        },
        {
            xtype: 'dataview',
            userCls: 'files',
            name: 'files',
            reference: 'files',
            padding: '3 4 0 4',
            maxWidth: 600,
            height: 0,
            border: 0,
            margin: 0,
            flex: 1,
            selectionModel: {
                mode: 'MULTI'
            },
            overItemCls: 'x-item-over',
            tpl: [
                '<tpl for=".">',
                    '<div class="file" tabindex="-1" data-status="{status}" style="--percent: {percent}">',
                        '<div class="text">{title}</div>',
                        '<div class="ring"></div>',
                        '<div class="drop fa fa-close">&nbsp;</div>',
                    '</div>',
                '</tpl>',
                {
                    attr: function(id) {
                        var rec = this.owner.getStore().getById(id),
                            cls = ['file'], attr = [], style = [];

                        if (rec.get('percent')) {
                            attr.push('style="--percent: ' + rec.get('percent') + '"');
                        }

                        return attr.join(' ');
                    },
                }
            ],
            itemSelector: '.file',
            store: {
                type: 'json',
                storeId: 'files',
                data: []
            },
        },
        {
            xtype: 'filebutton',
            style: 'background: transparent; border: transparent;',
            ui: 'default-toolbar',
            width: 30,
            height: 0,
            multiple: true,
            userCls: 'filebutton',
            margin: '0',
            glyph: 'xf0c6@FontAwesome',
            glyph: 'x2b@FontAwesome',
        },
        {
            xtype: 'container',
            layout: 'hbox',
            margin: '0 0 0 0',
            padding: 0,
            defaults: {
                margin: 0
            },
            items: [
                {
                    layout: 'hbox',
                    columns: 2,
                    flex: 1,
                    fieldLabel: false,
                    isCustomField: true,
                    bind: {
                        value: '{draft.purpose}'
                    },
                    //disabledOptions: 'improve',
                },
                {
                    flex: 0.9,
                    labelWidth: 50,
                    isCustomField: true,
                    itemId: 'aimodelId'
                }
            ],
        },
    ],
    constructor: function(config) {
        Ext.merge(config.viewModel, this.viewModelCfg);
        this.items[1].store.data = config.viewModel.data.draft._nested.aipromptFile;
        Ext.merge(this.items[3].items[0], config.purpose);
        Ext.merge(this.items[3].items[1], config.aimodelId);
        this.callParent(arguments);
    },
    uploaded: function(fileId, percent) {
        var rec = this.down('dataview').getStore().getById(fileId);

        // Setup upload progress
        rec.set({percent: percent, status: 'uploading-ai'});

        // Delay 'uploaded' status a bit, to show the full circle
        if (percent === 100) Ext.defer(() => rec && rec.set('status', 'uploaded'), 500);
    },
    apikey: function(msg) {

        // Trigger the API key prompt to be shown for the user
        if (!this.apikeyCalled) Indi.load('/entities/build/apikey/', {
            params: {
                msg: msg
            }
        });

        // We'll reach this point when API key is missing or invalid for a certain AI model,
        // so the Indi Engine should prompt the user to input an API key. However, we should
        // prevent duplicated/excessive prompts from being shown to the user, which can happen
        // when multiple files are selected at once for being be attached to AI prompt
        this.apikeyCalled = true;
    }
});