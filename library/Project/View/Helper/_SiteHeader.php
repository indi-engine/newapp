<?php
class Project_View_Helper_SiteHeader {
    public function siteHeader(){
        ob_start();?>
    <!DOCTYPE HTML>
    <html>
    <head>
        <meta charset="utf-8">
        <?=Indi::view()->siteFavicon()?>
        <title><?=Indi::view()->siteMetatag('title')?></title>
        <meta name="description" content="<?=Indi::view()->siteMetatag('description')?>">
        <meta name="keywords" content="<?=Indi::view()->siteMetatag('keywords')?>">
        <link rel="stylesheet" type="text/css" href="/css/style.css">
        <link rel="stylesheet" type="text/css" href="/css/adjust.css">
        <script src="/js/jquery-1.9.1.min.js"></script>
        <script src="/js/jquery.scrollTo-min.js"></script>
    </head>
    header
   <? return ob_get_clean();
    }
}