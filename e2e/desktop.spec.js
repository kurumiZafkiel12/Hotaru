import {test,expect} from '@playwright/test';
test('桌面编辑、存储、工具箱与多跳校验',async({page})=>{
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('/');await expect(page.getByRole('heading',{name:'一点微光，自在连接。'})).toBeVisible();
 await page.getByRole('button',{name:'自定义桌面'}).click();
 await page.getByRole('button',{name:'移除出口 IP'}).click();
 await page.reload();await expect(page.locator('[data-id="ip"]')).toHaveCount(0);
 await page.getByRole('button',{name:'自定义桌面'}).click();await page.getByRole('button',{name:'＋ 出口 IP'}).click();
 await page.getByRole('button',{name:'前移出口 IP'}).click();await expect(page.locator('[data-id]').nth(2)).toHaveAttribute('data-id','ip');
 await page.getByRole('button',{name:/工具箱/}).click();await expect(page.getByRole('button',{name:'IP 质量 · 开发中'})).toBeDisabled();
 await page.getByRole('button',{name:/代理链/}).click();await page.getByLabel('节点顺序').fill('a\na');await page.getByRole('button',{name:'检查路径'}).click();await expect(page.locator('#chain-result')).toContainText('不能重复');
 await page.getByLabel('节点顺序').fill('入口\n中转\n出口');await page.getByRole('button',{name:'检查路径'}).click();await expect(page.locator('#chain-result')).toContainText('草稿有效');
 await page.screenshot({path:'test-results/chain.png',fullPage:true});expect(errors).toEqual([]);
});
test('窄屏不产生横向溢出',async({page})=>{await page.setViewportSize({width:390,height:844});await page.goto('/');expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);});
