Ext.define('Indi.controller.doctorTariffs', {
    extend: 'Indi.Controller',
    actionsConfig: {
        index: {
            gridColumnDefault: function(field) {
                return Ext.merge(this.callParent(arguments), {
                    sortable: false,
                    menuDisabled: true
                });
            },
            panel: {
                /**
                 * Docked items special config
                 */
                docked: {
                    items: [{alias: 'filter'}, {alias: 'master'}, {alias: 'info'}]
                }
            },
            /**
             * Rowset panel paging toolbar builder
             *
             * @return {Object}
             */
            panelDocked$Info: function() {

                // Paging toolbar cfg
                return {
                    xtype: 'toolbar',
                    dock: 'top',
                    minHeight: 15,
                    padding: '0 0 0 0',
                    bodyPadding: 0,
                    items: ['<span style="color: blue;">Внимание: первый тариф в списке - это текущий активный тариф для выбранного врача. Список тарифов отсортирован в обратном хронологическом порядке. </span>']
                }
            }
        }
    }
});