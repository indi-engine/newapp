<?php
class Tariff_Row extends Indi_Db_Table_Row {

    /**
     * 
     *
     * @return int
     */
    public function save(){

        if (!$this->id) $this->adminId = Indi::admin()->id;

        // Standard save
        return parent::save();
    }
}