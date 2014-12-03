<?php
class TariffServiceGroup_Row extends Indi_Db_Table_Row {

    /**
     * @return int
     */
    public function save(){

        // Setup title
        $this->title = $this->foreign('serviceGroupId')->title . ' - ' . $this->price
            . ' ' . mb_lcfirst($this->foreign('measure')->title, 'utf-8');

        // Standard save
        return parent::save();
    }
}