<?php
class Doctor_Row extends Indi_Db_Table_Row {

    /**
     * @return int
     */
    public function save(){

        // Setup title
        $this->title = trim($this->sname . ' ' . $this->fname . ' ' . $this->tname);

        // Standard save
        return parent::save();
    }

    /**
     * Get the doctor's current active tariff
     *
     * @return Indi_Db_Table_Row|null
     */
    public function tariff() {
        return $this->nested('TariffComplex', array(
            'where' => '`for` = "doctor"',
            'order' => '`date` DESC',
            'count' => 1
        ))->at(0);
    }
}