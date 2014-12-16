Ext.define('Indi.controller.accurals', {
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
            storeFieldA: function() {
                var me = this, a = me.callParent(); a.push({name: 'pic', type: 'string'});
                return a;
            },
            gridColumn$FixedTariffQty: function(column) {
                return Ext.merge(column, {
                    cls: 'i-column-header-orderedQty'
                });
            },
            gridColumn$Title: function(column) {
                return Ext.merge(column, {
                    renderer: function(v, m, r) {
                        if (r) {
                            return r.raw._system.indent
                                + '<img src="' + r.get('pic') + '" style="position: absolute; margin: -3px 0 0 -5px;"/>'
                                + '&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;'
                                + v.replace(/&nbsp;/g, '');
                        }
                    }
                });
            },
            gridColumn$FloatTariffQty: function(column) {
                return Ext.merge(column, {
                    cls: 'i-column-header-orderedQty'
                });
            },
            gridColumn$ChiefTariffQty: function(column) {
                return Ext.merge(column, {
                    cls: 'i-column-header-orderedQty'
                });
            },
            gridColumn$BloodQty: function(column) {
                return Ext.merge(column, {
                    cls: 'i-column-header-orderedQty'
                });
            },
            gridColumn$SmearQty: function(column) {
                return Ext.merge(column, {
                    cls: 'i-column-header-orderedQty'
                });
            },
            gridColumn$SmearSum: function (column) {
                return Ext.merge(column, {
                    summaryType: 'sum',
                    summaryRenderer: function(value, summaryData, dataIndex) {
                        return '&sum;';
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