Ext.define('Indi.controller.doctorBasket', {
    extend: 'Indi.Controller',
    actionsConfig: {
        index: {
            panel: {
                docked: {
                    inner: {
                        master: [{alias: 'keyword', margin: '0 2 0 2'}, '-', {alias: 'actions'}, {alias: 'nested'}, '->']
                    }
                }
            },
            rowset: {
                features: [{
                    ftype: 'summary'
                }]
            },
            gridColumn$FixedTariffQty: function(column) {
                return Ext.merge(column, {
                    cls: 'i-column-header-orderedQty'
                });
            },
            gridColumn$FloatTariffQty: function(column) {
                return Ext.merge(column, {
                    cls: 'i-column-header-orderedQty'
                });
            },
            gridColumn$Salary: function (column) {
                return Ext.merge(column, {
                    summaryType: 'sum',
                    summaryRenderer: function(value, summaryData, dataIndex) {
                        return 'Итого';
                    }
                });
            },
            gridColumn$TotalSum: function (column) {
                return Ext.merge(column, {
                    summaryType: 'sum',
                    summaryRenderer: function(value, summaryData, dataIndex) {
                        return this.grid.headerCt.getGridColumns().r(dataIndex, 'dataIndex').renderer(value);
                    }
                });
            },
            gridColumn$TotalPaid: function (column) {
                return Ext.merge(column, {
                    summaryType: 'sum',
                    summaryRenderer: function(value, summaryData, dataIndex) {
                        return this.grid.headerCt.getGridColumns().r(dataIndex, 'dataIndex').renderer(value);
                    }
                });
            },
            gridColumn$TotalLeft: function (column) {
                return Ext.merge(column, {
                    summaryType: 'sum',
                    summaryRenderer: function(value, summaryData, dataIndex) {
                        return this.grid.headerCt.getGridColumns().r(dataIndex, 'dataIndex').renderer(value);
                    }
                });
            }
        }
    }
});