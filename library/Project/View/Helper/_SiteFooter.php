<?php
class Project_View_Helper_SiteFooter {
    public function siteFooter(){
        ob_start();?>
	footer
    <? return ob_get_clean();
    }
}