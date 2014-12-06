<?php
class Admin_DoctorBasketController extends Indi_Controller_Admin {
    public function adjustActionCfg() {
        $this->actionCfg['misc']['index']['ignoreTreeColumn'] = true;
    }
}