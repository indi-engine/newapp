<?php
class Month_Row extends Indi_Db_Table_Row {

    /**
     * @return int
     */
    public function save(){

        // Build title
        $this->title = $this->foreign('month')->title . ' ' . $this->foreign('yearId')->title;

        // Standard save
        return parent::save();
    }
}