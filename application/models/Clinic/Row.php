<?php
class Clinic_Row extends Indi_Db_Table_Row {

    /**
     * @return int
     */
    public function save(){

        // Standard save
        return parent::save();
    }

    /**
     * Get the clinic's current active tariff
     *
     * @return Indi_Db_Table_Row|null
     */
    public function tariff() {
        return $this->nested('TariffComplex', array(
            'where' => '`for` = "clinic"',
            'order' => '`date` DESC',
            'count' => 1
        ))->at(0);
    }
}