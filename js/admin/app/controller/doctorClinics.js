Ext.define('Indi.controller.doctorClinics', {
    extend: 'Indi.Controller',
    actionsConfig: {
        form: {
            formItem$ClinicId: function(item) {
                return {fieldLabel: 'Место работы'}
            },
            formItemA: function() {
                var me = this, itemA = me.callParent(), $span, $clinicId, $doctorId;
                $span = itemA.shift(), $clinicId = itemA.shift(), $doctorId = itemA.shift();
                itemA.unshift($clinicId); itemA.unshift($doctorId); itemA.unshift($span);
                return itemA;
            }
        }
    }
});