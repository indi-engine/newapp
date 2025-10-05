Ext.define('Indi.view.ai.PromptController', {
    extend: 'Ext.app.ViewController',
    alias: 'controller.aiprompt',
    listen: {
        store: {
            '#files': {
                datachanged: 'checkSubmittable'
            }
        }
    },
    control: {
        '#': {
            boxready: 'onBoxReady'
        },
        'textarea, formcombo': {
            change: 'onDraftChange'
        },
        'textarea': {
            keydown: 'onDraftKeyDown'
        },
        'dataview': {
            boxready: 'onFilesBoxReady',
            beforeitemclick: 'doFileDelete',
            itemkeyup: 'doFileDelete',
            paste: 'onFilesPaste'
        },
        'filebutton': {
            change: 'onFilesSelect'
        }
    },

    onBoxReady: function(aiprompt) {

        // Focus prompt textarea
        Ext.defer(() => aiprompt.down('textarea').focus(), 100);

        // If a retry for ai-upload should be made
        if (this.getViewModel().get('command') === 'retry-ai-upload') {

            // Foreach file attachment
            this.lookup('files').getStore().each(record => {

                // Set the status looking like before the API key prompt popped
                record.set('status', 'uploading-me');

                // Trigger AI-upload
                Ext.Ajax.request({url: `/aipromptFile/save/id/${record.get('id')}/ref/aiprompt/`});
            })
        }

        // Check submittable
        Ext.defer(() => this.checkSubmittable(), 100);
    },

    //
    checkSubmittable: function() {
        var me = this,
            prompt = me.lookup('prompt'),
            files = me.lookup('files').getStore(),
            submittable = true;

        // If some files are not yet uploaded to ai model - return false
        if (files.getCount() > files.query('status', 'uploaded').getCount()) {
            submittable = false;

        // Else if neither files are attached nor prompt text is given - return false
        } else if (files.getCount() === 0 && !prompt.getValue()) {
            submittable = false;
        }

        // Toggle OK button
        Ext.Msg.down('button#ok').setDisabled(!submittable);
    },

    onFilesPaste: async function (prompt, event) {
        var item, added = [], file, store = this.lookup('files').getStore();

        // Foreach pasted file - add to the files list
        if (event.browserEvent.clipboardData) for (item of event.browserEvent.clipboardData.items || []) {
            if (item.kind === "file" && (file = item.getAsFile())) {
                added = added.concat(
                    store.add({
                        title: file.name,
                        file: file,
                        status: 'uploading-me'
                    })
                );
            }
        }

        // Fit files list with prompt textarea
        this.doFilesFit();

        // Foreach selected file - do upload
        for (record of added) await this.doFileUpload(record);
    },

    onFilesSelect: async function(filebutton) {
        var added = [], file, store = this.lookup('files').getStore();

        // Foreach selected file - add to the files list
        for (file of filebutton.fileInputEl.dom.files) {
            added = added.concat(
                store.add({
                    title: file.name,
                    file: file,
                    status: 'uploading-me'
                })
            );
        }

        // Clear filebutton's files
        filebutton.fileInputEl.dom.value = '';

        // Fit files list with prompt textarea
        this.doFilesFit();

        // Foreach selected file - do upload
        for (record of added) await this.doFileUpload(record);
    },

    onDraftChange: function(field, value) {
        var draftId = this.getViewModel().get('draft.id'), params = {};

        // Prepare params
        params[field.name] = value;

        // Prevent flooding with xhr
        clearTimeout(this.draftChangeTimeout); this.draftChangeTimeout = setTimeout(() => {
            // Save draft
            Ext.Ajax.request({
                url: `/aiprompt/save/id/${draftId}/`,
                params: params
            });
        }, 500);

        // Disable OK button when needed
        this.checkSubmittable();
    },

    onFilesBoxReady: function(files) {

        // Fit files list
        this.doFilesFit();

        // Relay paste-event from prompt-textarea
        files.relayEvents(this.lookup('prompt'), ['paste']);
    },

    doFileUpload: async function(record) {
        var draftId = this.getViewModel().get('draft.id');

        // Prepare FormData object
        const formData = new FormData();
        formData.append("file", 'm');
        formData.append("file", record.get('file'), record.get('file').name);
        formData.append("title", record.get('file').name);

        // Make upload-request
        Ext.Ajax.request({
            url: `/aipromptFile/save/parent/${draftId}/ref/aiprompt/`,
            rawData: formData,
            headers: {
                'Content-Type': null
            },
            success: xhr => record.set({id: xhr.responseText.json().id}),
            failure: xhr => {
                this.lookup('files').getStore().remove(record);
                this.doFilesFit();
            }
        });
    },

    onDraftKeyDown: function(prompt, evt) {
        var dataview = this.lookup('files'),
            idx = 0,
            rec = dataview.getStore().getAt(idx);

        // If prompt text is empty
        if (!prompt.getValue() && rec) {

            // If pressed key is DELETE - delete all selected files or first attached file
            if (evt.keyCode === Ext.event.Event.DELETE) {
                this.doFileDelete(dataview, rec, null, idx, evt);

            // Else if Ctrl+A is pressed - select all files
            } else if (evt.ctrlKey && evt.keyCode === Ext.event.Event.A) {
                dataview.getSelectionModel().selectAll();
            }
        }
    },

    doFileDelete: function(dataview, rec, dom, idx, evt) {

        // If neither drop-icon was clicked nor DELETE key was pressed - return
        if (!evt.getTarget('.drop') && evt.keyCode !== Ext.event.Event.DELETE) {
            return;
        }

        // Prepare variables
        var params = {},
            store = dataview.getStore(),
            sm = dataview.getSelectionModel(), // selection model
            sr = dataview.getSelection(),      // selected records
            tbs;                               // one of the remaining record to be selected after deletion

        // Add current record to selection
        sr.push(rec);

        // Setup others-param
        sr.forEach(r => {
            r.get('id') !== rec.get('id') && (params[`others[${store.indexOf(r)}]`] = r.get('id'));
            r.set('status', 'deleting');
        });

        // Make delete request
        Ext.Ajax.request({
            url: `/aipromptFile/delete/id/${rec.data.id}/`,
            params: params,
            success: xhr => {

                // Remove from store
                sr.forEach(_rec => store.remove(_rec));

                // Fit files list
                this.doFilesFit();

                // If there is at least one remaining record
                if ((tbs = store.getAt(idx) || store.last())) {

                    // Select it
                    sm.select([tbs]);

                    // Focus files list for selection to be indicated
                    dataview.focus();
                }
            }
        })
    },

    doFilesFit: function() {
        var height = this.lookup('files').el.getHeight();
        this.lookup('prompt').inputEl.dom.style.paddingBottom = height + 'px';
        this.lookup('files').el.dom.style.marginTop = '-' + (height + 6) + 'px';
        this.lookup('files').focus();
        this.lookup('prompt').focus();
    },
});