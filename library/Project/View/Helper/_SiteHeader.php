<?php
class Project_View_Helper_SiteHeader extends Indi_View_Helper_Abstract{
    public function siteHeader(){
        ob_start();?>
    <!DOCTYPE HTML>
    <html>
    <head>
        <meta charset="utf-8">
        <?=$this->view->siteFavicon()?>
        <title><?=$this->view->seoTDK('title')?></title>
        <meta name="description" content="<?=$this->view->seoTDK('description')?>">
        <meta name="keywords" content="<?=$this->view->seoTDK('keyword')?>">
        <link rel="stylesheet" type="text/css" href="/css/style.css">
        <link rel="stylesheet" type="text/css" href="/css/adjust.css">
        <script src="/js/jquery-1.9.1.min.js"></script>
        <script src="/js/jquery-migrate-1.1.1.min.js"></script>
        <script src="/js/jquery.scrollTo-min.js"></script>
    </head>
    header
   <? return ob_get_clean();
    }
}