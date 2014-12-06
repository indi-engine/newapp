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
            },
            gridColumnA: function() {
                var me = this, plainColumnA = me.callParent(), groupedColumnA = Ext.clone(plainColumnA), groups;

                groupedColumnA = me.gridColumnAGroup(groupedColumnA, [
                    {text: 'Фиксированный тариф', start: 'fixedTariffId', span: 3},
                    {text: 'Прогрессивный тариф', start: 'floatTariffId', span: 3},
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