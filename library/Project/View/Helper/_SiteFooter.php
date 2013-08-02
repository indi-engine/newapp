<?php
class Project_View_Helper_SiteFooter extends Indi_View_Helper_Abstract{
    public function siteFooter(){
        ob_start();?>
	footer
    <? return ob_get_clean();
    }
}