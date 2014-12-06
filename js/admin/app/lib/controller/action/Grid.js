/**
 * Base class for all controller actions instances, that operate with rowsets,
 * and use Ext.panel.Grid view to display/modify those rowsets
 */
Ext.override(Indi.lib.controller.action.Grid, {

    gridColumnXNumber: function(column, field) {
        return {
            thousandSeparator: ' ',
            decimalSeparator: ',',
            decimalPrecision: 0,
            renderer: function(v, m, r, i, c, s) {
                if (v == '0') return '';
                var column = this.xtype == 'gridcolumn' ? this : this.headerCt.getGridColumns()[c];
                return Indi.numberFormat(v, column.decimalPrecision, column.decimalSeparator, column.thousandSeparator);
            }
        }
    },

});
