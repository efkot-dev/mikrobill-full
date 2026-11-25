<?php
/**
 * Plugin Name: MikroBILL Guard
 * Description: Ограничения для оператора WordPress в mikrobill-full: запрет обновления/установки/удаления ядра, тем и плагинов, создания администраторов, редактирования файлов и смены siteurl/home. Управление组件ами — только через образ (WP-CLI обходит guard).
 * Version:     0.2.0
 * Author:      efkot-dev
 * License:     GPL-2.0-or-later
 */

defined( 'ABSPATH' ) || exit;

// WP-CLI (entrypoint контейнера) обходит ограничения — иначе offline-update невозможен.
if ( defined( 'WP_CLI' ) && WP_CLI ) {
	return;
}

// 1. Запрет опасных действий: обновления, установка, удаление, редактор файлов.
add_filter( 'user_has_cap', function ( $allcaps, $caps, $args, $user ) {
	$blocked = array(
		'update_core', 'update_plugins', 'update_themes',
		'install_plugins', 'install_themes',
		'delete_plugins', 'delete_themes',
		'edit_files', 'edit_plugins', 'edit_themes',
	);
	foreach ( $blocked as $cap ) {
		$allcaps[ $cap ] = false;
	}
	return $allcaps;
}, 10, 4 );

// 2. Оператор не может создавать/повышать до Administrator и редактировать админов.
//    Роли Editor/Author остаются доступны — помощников оператор заводит сам.
add_filter( 'editable_roles', function ( $roles ) {
	unset( $roles['administrator'] );
	return $roles;
} );

// 3. Защита адреса сайта от смены через админку (меняет только entrypoint через WP-CLI).
foreach ( array( 'siteurl', 'home' ) as $mb_opt ) {
	add_filter( "pre_update_option_{$mb_opt}", function ( $value, $old_value ) {
		return $old_value;
	}, 10, 2 );
}
unset( $mb_opt );
