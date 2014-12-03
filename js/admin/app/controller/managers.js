Ext.define('Indi.controller.managers', {
    extend: 'Indi.Controller',
    actionsConfig: {
        form: {
            formItem$Email: function(item) {
                return {allowBlank: false, vtype: 'email'}
            },
        }
    }
});