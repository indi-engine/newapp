<?php
class Payment_Row extends Indi_Db_Table_Row {

    /**
     * @return int
     */
    public function save(){

        // Detect monthId
        list($y, $m) = explode('-', $this->date);
        $this->monthId = Indi::model('Month')->fetchRow('`month` = "' . $m . '" AND `yearId` = "'
            . Indi::model('Year')->fetchRow('`title` = "' . $y . '"')->id . '"')->id;

        // Setup title
        $this->title = 'от ' . $this->date . ' на сумму ' . $this->sum . ' руб.';

        if ($this->clinicId) {
            $clinicAccuralR = Indi::model('Accural')->fetchRow(array(
                '`monthId` = "' . $this->monthId . '"',
                '`clinicId` = "' . $this->clinicId . '"',
                '`for` = "clinic"',
            ));
            if ($clinicAccuralR) {
                $clinicAccuralR->totalPaid += $this->_modified['sum'] - $this->_original['sum'];
                $clinicAccuralR->save();
            }
        }

        // Standard save
        return parent::save();
    }
}