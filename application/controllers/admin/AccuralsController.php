<?php
class Admin_AccuralsController extends Indi_Controller_Admin {

    public function finalORDER($finalWHERE, $sort) {
        return parent::finalORDER($finalWHERE, $sort) . ', FIND_IN_SET(`doctorId`, "6,7")';
    }

    public function adjustGridDataRowset() {
        $this->rowset->foreign('clinicId,doctorId');
        foreach ($this->rowset as $r) {
            $r->pic = $r->foreign($r->for . 'Id')->src('pic', 'grid', true);
        }
    }
}