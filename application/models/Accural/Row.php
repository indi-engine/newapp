<?php
class Accural_Row extends Indi_Db_Table_Row {

    /**
     * @return int
     */
    public function save(){

        // Setup title
        $this->title = $this->foreign($this->for . 'Id')->title;

        // Calc the delta for `totalSum` property
        $delta = 0;
        foreach (ar('fixedTariffSum,floatTariffSum,chiefTariffSum,salary,bloodSum,smearSum') as $prop)
            if ($this->_modified[$prop]) $delta += $this->_modified[$prop] - $this->_original[$prop];

        // Apply it
        $this->totalSum += $delta;

        // Update `totalLeft` property
        $this->totalLeft = $this->totalSum - $this->totalPaid;

        // Standard save
        return parent::save();
    }
}