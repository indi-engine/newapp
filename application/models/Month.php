<?php
class Month extends Indi_Db_Table {

    /**
     * Classname for row
     *
     * @var string
     */
    public $_rowClass = 'Month_Row';

    /**
     * Return an instance of Month_Row class, representing current month within current year
     *
     * @return Month_Row
     */
    public function now() {

        // Extract 4-digit year and 2-digit month from a current date
        list($y, $m) = explode('-', date('Y-m-d'));

        // If there is no such a year entry found
        if (!$yearR = Indi::model('Year')->fetchRow('`title` = "' . $y . '"')) {

            // Create it
            $yearR = Indi::model('Year')->createRow()->assign(array('title' => $y));
            $yearR->save();
        }


        // If there is no such a month entry found
        if (!$monthR = $this->fetchRow('`month` = "' . $m . '" AND `yearId` = "' . $yearR->id . '"')) {

            // Create it
            $monthR = $this->createRow()->assign(array('month' => $m, 'yearId' => $yearR->id));
            $monthR->save();
        }

        // Return month row
        return $monthR;
    }
}