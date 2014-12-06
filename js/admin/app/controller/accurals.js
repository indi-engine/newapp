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
            },
            gridColumnA: function() {
                var me = this, plainColumnA = me.callParent(), groupedColumnA = Ext.clone(plainColumnA), groups;

                groupedColumnA = me.gridColumnAGroup(groupedColumnA, [
                    {text: 'Фиксированный тариф', start: 'fixedTariffId', span: 3},
                    {text: 'Прогрессивный тариф', start: 'floatTariffId', span: 3},
                    {text: 'Руководительский тариф', start: 'chiefTariffId', span: 3},
                    {text: 'Кровь', start: 'bloodQty', span: 2},
                    {text: 'Мазок', start: 'smearQty', span: 2},
                    {text: 'Суммы', start: 'totalSum', span: 3},
                ]);

                return groupedColumnA;
            },

            gridColumnAGroup: function(columnA, groupA) {
                var inspan;
                for (var i = 0; i < groupA.length; i++) if (groupA[i].span > 1)
                    for (var j = 0; j < columnA.length; j++) if (columnA[j].dataIndex == groupA[i].start) {
                        inspan = columnA.splice(j, groupA[i].span);
                        columnA.splice(j, 0, {
                            text: groupA[i].text,
                            columns: inspan
                        });
                        break;
                    }

                return columnA;
            }
        }
    }
});