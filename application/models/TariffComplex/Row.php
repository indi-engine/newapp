<?php
class TariffComplex_Row extends Indi_Db_Table_Row {

    /**
     * @return int
     */
    public function save(){

        // Detect and setup `monthId` and `yearId`
        list($y, $m) = explode('-', $this->date);
        $this->yearId = Indi::model('Year')->fetchRow('`title` = "' . $y . '"')->id;
        $this->monthId = Indi::model('Month')->fetchRow('`month` = "' . $m . '" AND `yearId` = "' . $this->yearId . '"')->id;

        // Standard save
        return parent::save();
    }
}