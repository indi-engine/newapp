<?foreach($this->tree as $item) {?>
    <a style="margin-left: <?=$item['level']*20?>px;" href="<?=$item['href']?>"><?=$item['title']?></a><br>
<?}?>
